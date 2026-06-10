import logging
import re
import time
from typing import Any, Dict, Tuple, Union, TypedDict, Optional, List
from dataclasses import dataclass
from urllib.parse import urlparse, urlunparse

from streamlink.exceptions import StreamError
from streamlink.plugin import Plugin, pluginmatcher
from streamlink.plugin.api import validate
from streamlink.stream.hls import (
    HLSStream,
    HLSStreamReader,
    HLSStreamWorker,
    parse_m3u8,
)

log = logging.getLogger(__name__)


class ChzzkHLSStreamWorker(HLSStreamWorker):
    """
    Custom HLS Stream Worker for Chzzk.
    """

    stream: "ChzzkHLSStream"

    def _fetch_playlist(self) -> Any:
        # Refresh the stream token once and retry on any failure. Crucially, never
        # let a non-StreamError (network / parse / attribute error) escape: the HLS
        # worker only handles StreamError gracefully (logs and stops). Anything else
        # crashes the worker thread ("Exception in thread ...") and silently stalls
        # the recording, so every failure is funnelled into a StreamError here.
        last_err = None
        for attempt in range(2):  # refresh the stream URL once, then retry
            try:
                return super()._fetch_playlist()
            except Exception as err:  # noqa: BLE001 - broad on purpose, for resilience
                last_err = err
                if attempt >= 1:
                    break
                log.warning(f"Playlist fetch failed, refreshing stream URL: {err}")
                try:
                    self.stream.refresh_playlist()
                    log.debug("Refreshed the channel playlist after a fetch error.")
                except Exception as refresh_err:  # noqa: BLE001
                    last_err = refresh_err
                    break
        raise StreamError(f"Failed to fetch playlist after retries: {last_err}")


class ChzzkHLSStreamReader(HLSStreamReader):
    """
    Custom HLS Stream Reader for Chzzk.
    """

    __worker__ = ChzzkHLSStreamWorker


class ChzzkHLSStream(HLSStream):
    """
    Custom HLS Stream for Chzzk with token refresh capability.
    """

    __shortname__ = "hls-chzzk"
    __reader__ = ChzzkHLSStreamReader

    _REFRESH_BEFORE = 3 * 60 * 60  # 3 hours

    def __init__(self, session, url: str, channel_id: str, *args, **kwargs) -> None:
        super().__init__(session, url, *args, **kwargs)
        self._url = url
        self._channel_id = channel_id
        self._api = ChzzkAPI(session)
        self._expire = self._get_expire_time(url)
        self._last_proactive_refresh = 0.0
        self._refresh_interval = 60.0

    def refresh_playlist(self) -> None:
        """
        Refresh the stream URL to get a new token and handle domain change.
        """
        log.debug("Refreshing the stream URL to get a new token.")
        datatype, data = self._api.get_live_detail(self._channel_id)
        if datatype == "error":
            raise StreamError(data)
        if not data or len(data) < 2:
            raise StreamError("Error occurred while refreshing the stream URL.")
        media, status, *_ = data
        if status != "OPEN" or media is None:
            raise StreamError("The stream is no longer available.")
        want = self._quality_tag(self._url)
        for media_info in media:
            if (
                len(media_info) >= 3
                and media_info[1] == "HLS"
                and media_info[0] == "HLS"
            ):
                media_path = self._update_domain(media_info[2])
                streams = ChzzkHLSStream.parse_variant_playlist(
                    self.session, media_path, channel_id=self._channel_id)
                if not streams:
                    continue
                # Chzzk embeds the CDN token in the URL *path* (hdntl=exp=...~hmac=...),
                # which changes on every refresh, so adopt the whole fresh URL instead of
                # splicing a query token. Keep the current quality when we can match it.
                chosen = None
                if want is not None:
                    chosen = next(
                        (s for s in streams.values() if self._quality_tag(s._url) == want),
                        None)
                chosen = chosen or next(iter(streams.values()))
                self._url = self._update_domain(chosen._url)
                self._expire = self._get_expire_time(self._url)
                log.debug(f"Refreshed the stream URL (quality={want}).")
                return
        raise StreamError("No valid HLS stream found in the refreshed playlist.")

    def _update_domain(self, url: str) -> str:
        """
        Update the domain of the given URL if it matches specific criteria.
        """
        parsed = urlparse(url)
        if parsed.hostname == "livecloud.pstatic.net":
            return urlunparse(parsed._replace(netloc="nlive-streaming.navercdn.com"))
        return url

    def _get_expire_time(self, url: str) -> Optional[int]:
        """
        Extract the token expiration timestamp from the URL. Chzzk has used several
        layouts over time — an `exp` query parameter, an `exp=` inside the `hdnts`
        query value, and an `exp=` inside a path token (.../hdntl=exp=<ts>~...) — so
        just find the first `exp=<digits>` anywhere in the URL. Returns None when it
        is absent, in which case only the reactive on-failure refresh applies.
        """
        match = re.search(r"exp=(\d+)", url)
        return int(match.group(1)) if match else None

    @staticmethod
    def _quality_tag(url: str) -> Optional[str]:
        """Resolution segment in the path (e.g. '1080p'), used to keep quality on refresh."""
        match = re.search(r"/(\d+p(?:\d+)?)/", urlparse(url).path)
        return match.group(1) if match else None

    def _should_refresh(self) -> bool:
        """
        Determine if the stream URL should be refreshed based on expiration time.
        """
        return (
            self._expire is not None
            and time.time() >= self._expire - self._REFRESH_BEFORE
        )

    @property
    def url(self) -> str:
        # Proactive refresh, rate-limited. Never let a refresh failure propagate —
        # this property is read on the worker thread, so fall back to the current
        # URL and let the _fetch_playlist retry path handle real expiry.
        if self._should_refresh() and (time.time() - self._last_proactive_refresh) >= self._refresh_interval:
            self._last_proactive_refresh = time.time()
            try:
                self.refresh_playlist()
                # If even a fresh token expires within the threshold, the CDN is
                # issuing short-lived tokens: back off so this does not turn into a
                # refresh-every-minute loop. Reset once tokens are long-lived again.
                self._refresh_interval = 600.0 if self._should_refresh() else 60.0
            except Exception as err:  # noqa: BLE001
                log.warning(f"Proactive stream URL refresh failed, keeping current URL: {err}")
        return self._url


class LiveDetail(TypedDict):
    status: str
    liveId: int
    liveTitle: Union[str, None]
    liveCategory: Union[str, None]
    adult: bool
    channel: str
    media: List[Dict[str, str]]


@dataclass
class ChzzkAPI:
    """
    API client for Chzzk.
    """

    session: Any
    _CHANNELS_LIVE_DETAIL_URL: str = (
        "https://api.chzzk.naver.com/service/v3/channels/{channel_id}/live-detail"
    )

    def _query_api(
        self, url: str, *schemas: validate.Schema
    ) -> Tuple[str, Union[Dict[str, Any], str]]:
        response = self.session.http.get(
            url,
            acceptable_status=(200, 404),
            headers={"Referer": "https://chzzk.naver.com/"},
            schema=validate.Schema(
                validate.parse_json(),
                validate.any(
                    validate.all(
                        {
                            "code": int,
                            "message": str,
                        },
                        validate.transform(lambda data: ("error", data["message"])),
                    ),
                    validate.all(
                        {
                            "code": 200,
                            "content": None,
                        },
                        validate.transform(lambda _: ("success", None)),
                    ),
                    validate.all(
                        {
                            "code": 200,
                            "content": dict,
                        },
                        validate.get("content"),
                        *schemas,
                        validate.transform(lambda data: ("success", data)),
                    ),
                ),
            ),
        )
        return response

    def get_live_detail(self, channel_id: str) -> Tuple[str, Union[LiveDetail, str]]:
        """
        Get live stream details for a given channel.
        """
        return self._query_api(
            self._CHANNELS_LIVE_DETAIL_URL.format(channel_id=channel_id),
            {
                "status": str,
                "liveId": int,
                "liveTitle": validate.any(str, None),
                "liveCategory": validate.any(str, None),
                "adult": bool,
                "channel": validate.all(
                    {"channelName": str},
                    validate.get("channelName"),
                ),
                "livePlaybackJson": validate.none_or_all(
                    str,
                    validate.parse_json(),
                    {
                        "media": [
                            validate.all(
                                {
                                    "mediaId": str,
                                    "protocol": str,
                                    "path": validate.url(),
                                },
                                validate.union_get(
                                    "mediaId",
                                    "protocol",
                                    "path",
                                ),
                            ),
                        ],
                    },
                    validate.get("media"),
                ),
            },
            validate.union_get(
                "livePlaybackJson",
                "status",
                "liveId",
                "channel",
                "liveCategory",
                "liveTitle",
                "adult",
            ),
        )


@pluginmatcher(
    name="live",
    pattern=re.compile(
        r"https?://chzzk\.naver\.com/live/(?P<channel_id>[A-Za-z0-9_-]{1,128})",
    ),
)
class Chzzk(Plugin):
    """
    Plugin for Chzzk live streams.
    """

    _STATUS_OPEN = "OPEN"

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._api = ChzzkAPI(self.session)
        self.author: Optional[str] = None
        self.category: Optional[str] = None
        self.title: Optional[str] = None

    def _get_live(self, channel_id: str) -> Optional[Dict[str, HLSStream]]:
        datatype, data = self._api.get_live_detail(channel_id)
        if datatype == "error":
            log.error(data)
            return None
        if data is None:
            return None

        if len(data) < 7:
            log.error("Incomplete data received from API.")
            return None

        media, status, self.id, self.author, self.category, self.title, adult = data
        if status != self._STATUS_OPEN:
            log.error("The stream is unavailable")
            return None
        if media is None:
            log.error(f"This stream is {'for adults only' if adult else 'unavailable'}")
            return None

        streams = {}
        for media_info in media:
            if (
                len(media_info) >= 3
                and media_info[1] == "HLS"
                and media_info[0] == "HLS"
            ):
                media_path = self._update_domain(media_info[2])
                hls_streams = ChzzkHLSStream.parse_variant_playlist(
                    self.session,
                    media_path,
                    channel_id=channel_id,
                )
                if hls_streams:
                    streams.update(hls_streams)
        if not streams:
            log.error("No valid HLS streams found.")
            return None
        return streams

    def _update_domain(self, url: str) -> str:
        """
        Update the domain of the given URL if it matches specific criteria.
        """
        parsed = urlparse(url)
        if parsed.hostname == "livecloud.pstatic.net":
            return urlunparse(parsed._replace(netloc="nlive-streaming.navercdn.com"))
        return url

    def _get_streams(self) -> Optional[Dict[str, HLSStream]]:
        if self.matches["live"]:
            return self._get_live(self.match["channel_id"])
        return None


__plugin__ = Chzzk
