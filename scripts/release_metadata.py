#!/usr/bin/env python3
import json
import shlex
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METADATA_PATH = ROOT / "release.json"


def load_metadata():
    with METADATA_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def require_string(data, path):
    current = data
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            raise SystemExit(f"release.json missing key: {path}")
        current = current[key]
    if not isinstance(current, str) or not current.strip():
        raise SystemExit(f"release.json key must be a non-empty string: {path}")
    return current


def shell_env(data):
    mapping = {
        "APP_NAME": require_string(data, "app.name"),
        "BIN_NAME": require_string(data, "app.executable"),
        "BUNDLE_ID": require_string(data, "app.bundleIdentifier"),
        "MIN_MACOS": require_string(data, "app.minimumMacOS"),
        "MARKETING_VERSION": require_string(data, "version.marketing"),
        "BUILD_NUMBER": require_string(data, "version.build"),
        "CHANGELOG_HEADING": require_string(data, "version.changelogHeading"),
        "DMG_BASENAME": require_string(data, "distribution.dmgBaseName"),
        "DMG_VOLUME_NAME": require_string(data, "distribution.volumeName"),
        "COPYRIGHT_TEXT": require_string(data, "legal.copyright"),
        "LICENSE_FILE": require_string(data, "legal.licenseFile"),
        "THIRD_PARTY_NOTICES_FILE": require_string(data, "legal.thirdPartyNoticesFile"),
        "CHANGELOG_FILE": require_string(data, "legal.changelogFile"),
    }
    for key, value in mapping.items():
        print(f"{key}={shlex.quote(value)}")


def validate(data):
    required_files = [
        require_string(data, "legal.licenseFile"),
        require_string(data, "legal.thirdPartyNoticesFile"),
        require_string(data, "legal.changelogFile"),
        "Sources/ChzzkDownloader/Resources/en.lproj/Localizable.strings",
        "Sources/ChzzkDownloader/Resources/ko.lproj/Localizable.strings",
    ]
    for doc in data.get("supportDocuments", []):
        source = doc.get("source")
        dmg_name = doc.get("dmgName")
        if not source or not dmg_name:
            raise SystemExit("supportDocuments entries need source and dmgName")
        required_files.append(source)

    missing = [path for path in required_files if not (ROOT / path).exists()]
    if missing:
        raise SystemExit("missing release source files:\n" + "\n".join(missing))

    changelog = (ROOT / require_string(data, "legal.changelogFile")).read_text(encoding="utf-8")
    heading = require_string(data, "version.changelogHeading")
    if f"## {heading}" not in changelog:
        raise SystemExit(f"CHANGELOG.md is missing heading: ## {heading}")

    print("release metadata OK")


def dmg_docs(data):
    docs = data.get("supportDocuments", [])
    if not isinstance(docs, list):
        raise SystemExit("supportDocuments must be an array")
    for doc in docs:
        source = doc.get("source")
        dmg_name = doc.get("dmgName")
        if not source or not dmg_name:
            raise SystemExit("supportDocuments entries need source and dmgName")
        print(f"{source}\t{dmg_name}")


def value(data, path):
    print(require_string(data, path))


def main():
    data = load_metadata()
    command = sys.argv[1] if len(sys.argv) > 1 else "validate"
    if command == "env":
        shell_env(data)
    elif command == "validate":
        validate(data)
    elif command == "dmg-docs":
        dmg_docs(data)
    elif command == "value" and len(sys.argv) == 3:
        value(data, sys.argv[2])
    else:
        raise SystemExit("usage: release_metadata.py [env|validate|dmg-docs|value <path>]")


if __name__ == "__main__":
    main()
