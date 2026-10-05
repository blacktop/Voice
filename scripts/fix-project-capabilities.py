#!/usr/bin/python3
"""Repair XcodeGen #1637 without rewriting unrelated project fields."""

import json
import re
import subprocess
import sys
from pathlib import Path

# OpenStep plist scalars are strings when decoded by plutil.
CAPABILITIES = {"com.apple.Keychain": {"enabled": "1"}}
MALFORMED = '["com.apple.Keychain": ["enabled": 1]]'


def parse_project(data):
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "-"],
        input=data,
        capture_output=True,
        check=True,
        timeout=10,
    )
    return json.loads(result.stdout)


def voice_attributes(project):
    objects = project["objects"]
    targets = [
        key
        for key, value in objects.items()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Voice"
    ]
    if len(targets) != 1:
        raise ValueError("expected exactly one Voice native target")
    root = objects[project["rootObject"]]
    return root["attributes"]["TargetAttributes"][targets[0]]


def repair(path):
    data = path.read_bytes()
    expected = parse_project(data)
    attributes = voice_attributes(expected)
    value = attributes.get("SystemCapabilities")
    if value == CAPABILITIES:
        return
    if value != MALFORMED:
        raise ValueError("unexpected Voice SystemCapabilities; review the XcodeGen workaround")

    pattern = (
        rb"(?m)^([\t ]*)SystemCapabilities = " + re.escape(json.dumps(MALFORMED).encode()) + rb";$"
    )

    def replacement(match):
        indent = match[1]
        return b"\n".join(
            [
                indent + b"SystemCapabilities = {",
                indent + b"\tcom.apple.Keychain = {",
                indent + b"\t\tenabled = 1;",
                indent + b"\t};",
                indent + b"};",
            ]
        )

    repaired, count = re.subn(pattern, replacement, data)
    attributes["SystemCapabilities"] = CAPABILITIES
    if count != 1 or parse_project(repaired) != expected:
        raise ValueError("could not isolate Voice's Keychain capability")
    path.write_bytes(repaired)


if __name__ == "__main__":
    try:
        repair(Path(sys.argv[1]))
    except (IndexError, KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"Project capability repair failed: {error}")
