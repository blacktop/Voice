#!/usr/bin/python3
"""Validate Voice's profile-bound entitlements before installation."""

import datetime
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
GROUPS = "keychain-access-groups"
HARDENED = "com.apple.security.hardened-process"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def grants(allowed, claimed):
    if type(allowed) is not type(claimed):
        return False
    if isinstance(claimed, str):
        if "*" in claimed:
            return False
        if allowed.endswith("*") and allowed.count("*") == 1:
            return claimed.startswith(allowed[:-1])
    return allowed == claimed


def validate(profile, signed, bundle_id, team_id, certificate, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, datetime.datetime), "profile has no expiration date")
    require(
        expiration.replace(tzinfo=datetime.timezone.utc) > now,
        "embedded provisioning profile has expired",
    )
    require("OSX" in profile.get("Platform", []), "profile does not support macOS")
    require(
        certificate in profile.get("DeveloperCertificates", []),
        "profile does not authorize the app's signing certificate",
    )

    authorized = profile.get("Entitlements", {})
    app_id = signed.get(APP_ID, "")
    suffix = "." + bundle_id
    prefix = app_id.removesuffix(suffix)
    require(
        bundle_id and app_id.endswith(suffix) and prefix and "*" not in app_id,
        "Voice lacks a provisioned application identifier",
    )
    require(
        prefix in profile.get("ApplicationIdentifierPrefix", [])
        and authorized.get(APP_ID) == app_id,
        "profile does not authorize Voice's explicit application identifier",
    )
    require(
        team_id
        and team_id != "not set"
        and signed.get(TEAM_ID) == team_id
        and authorized.get(TEAM_ID) == team_id
        and team_id in profile.get("TeamIdentifier", []),
        "profile team does not match the app's signature",
    )
    require(signed.get(GROUPS) == [app_id], "Voice does not use its private Keychain group")
    require(
        isinstance(authorized.get(GROUPS), list)
        and any(grants(group, app_id) for group in authorized[GROUPS]),
        "profile does not authorize Voice's Keychain group",
    )
    for key, claimed in signed.items():
        if key == HARDENED or key.startswith(HARDENED + "."):
            require(
                key in authorized and grants(authorized[key], claimed),
                f"profile does not authorize {key}",
            )


def run(command):
    try:
        return subprocess.run(command, capture_output=True, check=True, timeout=30).stdout
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise ValueError(f"{Path(command[0]).name} failed: {detail}") from error


def signing_certificate(app):
    with tempfile.TemporaryDirectory(prefix="voice-profile-") as directory:
        prefix = str(Path(directory) / "signer")
        run(["/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", str(app)])
        return Path(prefix + "0").read_bytes()


def verify(app, entitlements, signature):
    profile_path = app / "Contents/embedded.provisionprofile"
    require(profile_path.is_file(), "Voice has no embedded provisioning profile")
    profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]))
    signed = plistlib.loads(entitlements.read_bytes())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    team_id = next(
        (
            line.removeprefix("TeamIdentifier=")
            for line in signature.read_text().splitlines()
            if line.startswith("TeamIdentifier=")
        ),
        "",
    )
    validate(profile, signed, info["CFBundleIdentifier"], team_id, signing_certificate(app))


if __name__ == "__main__":
    try:
        verify(*(Path(argument) for argument in sys.argv[1:]))
    except (KeyError, OSError, TypeError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"Security verification failed: {error}")
