# VOD Partial Download Policy

## Invariant

구간 다운로드는 가능한 한 반드시 파트/세그먼트 단위로 받아야 한다.

- DASH 매니페스트가 `SegmentTemplate` / `SegmentTimeline` 파트를 제공하면 `clipStart` / `clipEnd`에 겹치는 media segment만 다운로드한다.
- HLS 라이브 리와인드도 `#EXTINF` 세그먼트 중 구간에 겹치는 조각만 다운로드한다.
- 파트 목록이 없는 직접 MP4/CDN URL 구간은 `parallelClipPostprocess`로 byte-range window만 병렬로 받은 뒤 로컬 처리한다.
- 직접 MP4 byte-range window는 **MP4 `moov` 샘플 테이블(`stts`/`stss`/`stsc`/`stsz`·`stz2`/`stco`·`co64`)을 파싱해 정확한 byte 구간을 계산**한다. 시간÷전체길이 비율로 byte 위치를 추정하는 선형 방식은 VBR에서 크게 어긋나므로 사용하지 않는다. (`MP4ClipIndex.clipByteSpan`)
- 받는 범위는 `ftyp`+`moov`+`mdat` 헤더(메타데이터)와 `clipStart` 직전 키프레임부터 `clipEnd`까지의 샘플 byte span뿐이며, 그 사이 mdat은 sparse hole로 둔다.
- `moov`를 찾거나 파싱하지 못하면(예: fragmented MP4, moov 위치 비정상) 추정으로 진행하지 말고 `-ss`를 입력 앞에 둔 ffmpeg HTTP range seek로 폴백한다.
- `init.mp4` / `EXT-X-MAP` 같은 초기화 세그먼트는 필요한 경우 함께 받는다.
- 받은 로컬 파트 묶음은 ffmpeg로 최종 구간만 remux/cut한다.

## Do Not Regress

다음 변경은 금지한다.

- DASH/HLS 파트 목록이 있는데도 전체 파일을 먼저 받은 뒤 자르는 방식.
- 구간 시작이 늦은 영상에서 `0초부터 clipEnd까지` prefix를 받는 방식.
- `VODSegmentPlan.selectedMedia(...)`를 우회해서 모든 이전 세그먼트를 받는 방식.

prefix byte-range 다운로드는 구간 다운로드 fallback으로도 허용하지 않는다. 파트 목록이 없는 직접 MP4/CDN URL은 병렬 byte-range window를 우선 사용하고, 실패 시 원격 seek를 사용한다.

## Required Tests When Editing

VOD 부분 다운로드 코드를 수정할 때는 최소한 다음을 확인한다.

- DASH `SegmentTemplate` / `SegmentTimeline` 파싱이 media part URL과 시작/길이를 보존한다.
- `clipStart` / `clipEnd` 선택이 겹치는 파트만 반환한다.
- `VODDownloader.strategy(...)`가 DASH 파트 목록이 있는 variant를 `dashSegmentPrefetch`로 보낸다.
- 파트 목록이 없는 직접 MP4 구간은 `parallelClipPostprocess`로 보내고 `parallelPostprocess` prefix로 보내지 않는다.
- 직접 MP4 byte-range window가 `0초부터 clipEnd까지` prefix가 아니라 metadata와 `moov`로 계산한 구간 byte span만 선택하는지 확인한다.
- `MP4ClipIndex.clipByteSpan`이 키프레임≤clipStart부터 clipEnd까지의 byte 구간을 반환하고, 파싱 실패 시 nil(→ 원격 seek 폴백)을 반환하는지 확인한다.

이 정책을 바꾸려면 사용자에게 명시적으로 확인받아야 한다.
