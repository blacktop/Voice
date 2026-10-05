import copy
import datetime
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capability = load_script("fix-project-capabilities")
provisioning = load_script("verify-provisioning")
TEAM = "TESTTEAM01"
BUNDLE = "io.blacktop.Voice"
APP = f"{TEAM}.{BUNDLE}"
CERTIFICATE = b"test signing certificate"
NOW = datetime.datetime(2026, 10, 4, tzinfo=datetime.timezone.utc)


def signed_entitlements():
    with (ROOT / "Configs/Voice.entitlements").open("rb") as source:
        signed = plistlib.load(source)
    signed[provisioning.APP_ID] = APP
    signed[provisioning.TEAM_ID] = TEAM
    signed[provisioning.GROUPS] = [APP]
    return signed


def profile_fixture(signed):
    authorized = {
        key: value for key, value in signed.items() if key.startswith(provisioning.HARDENED)
    }
    authorized.update(
        {
            provisioning.APP_ID: APP,
            provisioning.TEAM_ID: TEAM,
            provisioning.GROUPS: [TEAM + ".*"],
        }
    )
    for key in authorized:
        if key.endswith(("-version-string", "-restrictions-string")):
            authorized[key] = "*"
    return {
        "ExpirationDate": NOW.replace(year=2027, tzinfo=None),
        "Platform": ["OSX"],
        "DeveloperCertificates": [CERTIFICATE],
        "ApplicationIdentifierPrefix": [TEAM],
        "TeamIdentifier": [TEAM],
        "Entitlements": authorized,
    }


class CapabilityTests(unittest.TestCase):
    def test_generated_voice_target_has_native_dictionary(self):
        path = ROOT / "Voice.xcodeproj/project.pbxproj"
        original = path.read_bytes()
        project = capability.parse_project(original)
        self.assertEqual(
            capability.voice_attributes(project)["SystemCapabilities"],
            capability.CAPABILITIES,
        )
        with tempfile.TemporaryDirectory() as directory:
            copy_path = Path(directory) / "project.pbxproj"
            copy_path.write_bytes(original)
            capability.repair(copy_path)
            self.assertEqual(copy_path.read_bytes(), original)

    def test_repair_preserves_other_attributes_and_rejects_unknown_shape(self):
        template = """{
            objects = {
                ROOT = {isa = PBXProject; attributes = {TargetAttributes = {
                    VOICE = {ProvisioningStyle = Automatic;
                        SystemCapabilities = VALUE;
                    };
                };};};
                VOICE = {isa = PBXNativeTarget; name = Voice;};
            };
            rootObject = ROOT;
        }"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            original = template.replace("VALUE", json.dumps(capability.MALFORMED)).encode()
            path.write_bytes(original)
            capability.repair(path)
            expected = capability.parse_project(original)
            capability.voice_attributes(expected)["SystemCapabilities"] = capability.CAPABILITIES
            self.assertEqual(capability.parse_project(path.read_bytes()), expected)
            unknown = template.replace("VALUE", '"unexpected"').encode()
            path.write_bytes(unknown)
            with self.assertRaisesRegex(ValueError, "unexpected"):
                capability.repair(path)
            self.assertEqual(path.read_bytes(), unknown)


class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.signed = signed_entitlements()
        self.profile = profile_fixture(self.signed)

    def validate(self, profile=None, signed=None, certificate=CERTIFICATE):
        provisioning.validate(
            self.profile if profile is None else profile,
            self.signed if signed is None else signed,
            BUNDLE,
            TEAM,
            certificate,
            NOW,
        )

    def test_authorized_explicit_profile_accepts_apple_wildcards(self):
        self.validate()
        exact = copy.deepcopy(self.profile)
        exact["Entitlements"].update(
            {
                key: value
                for key, value in self.signed.items()
                if key.startswith(provisioning.HARDENED)
            }
        )
        exact["Entitlements"][provisioning.GROUPS] = [APP]
        self.validate(exact)

    def test_rejects_expired_or_incompatible_profile_identity(self):
        cases = [
            ("ExpirationDate", NOW.replace(tzinfo=None), "expired"),
            ("ExpirationDate", "tomorrow", "expiration"),
            ("Platform", ["iOS"], "macOS"),
            ("DeveloperCertificates", [b"different"], "certificate"),
            ("ApplicationIdentifierPrefix", ["OTHER"], "application identifier"),
            ("TeamIdentifier", ["OTHER"], "team"),
        ]
        for key, value, message in cases:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile[key] = value
                with self.assertRaisesRegex(ValueError, message):
                    self.validate(profile)

    def test_rejects_wildcard_app_id_and_unauthorized_keychain(self):
        cases = [
            (provisioning.APP_ID, TEAM + ".*", "explicit application"),
            (provisioning.APP_ID, APP + ".other", "explicit application"),
            (provisioning.TEAM_ID, "OTHER", "team"),
            (provisioning.GROUPS, ["OTHER.*"], "Keychain"),
            (provisioning.GROUPS, [TEAM + ".?"], "Keychain"),
            (provisioning.GROUPS, None, "Keychain"),
        ]
        for key, value, message in cases:
            with self.subTest(key=key, value=value):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaisesRegex(ValueError, message):
                    self.validate(profile)
        signed = copy.deepcopy(self.signed)
        signed[provisioning.GROUPS].append(TEAM + ".other")
        with self.assertRaisesRegex(ValueError, "private Keychain"):
            self.validate(signed=signed)

    def test_rejects_every_missing_or_rejected_hardening_grant(self):
        for key, claimed in self.signed.items():
            if not key.startswith(provisioning.HARDENED):
                continue
            wrong_values = [None, False, 1] if type(claimed) is bool else [None, "1", True]
            for wrong in wrong_values:
                with self.subTest(key=key, wrong=wrong):
                    profile = copy.deepcopy(self.profile)
                    if wrong is None:
                        del profile["Entitlements"][key]
                    else:
                        profile["Entitlements"][key] = wrong
                    with self.assertRaisesRegex(ValueError, key):
                        self.validate(profile)

    def test_missing_profile_fails_before_decoder(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Voice.app"
            with self.assertRaisesRegex(ValueError, "no embedded"):
                provisioning.verify(app, app / "unused", app / "unused")

    def test_extracts_certificate_from_real_signed_executable(self):
        self.assertTrue(provisioning.signing_certificate(Path("/usr/bin/codesign")))

    def test_install_stops_before_copy_on_bad_profile(self):
        with tempfile.TemporaryDirectory(prefix="voice-signing-test-") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(ROOT / "justfile", root / "justfile")
            shutil.copy2(ROOT / "scripts/verify-provisioning.py", scripts)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "just").symlink_to(shutil.which("just"))
            contents = root / ".build/DerivedData-Release/Build/Products/Release/Voice.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE}))
            (contents / "embedded.provisionprofile").write_bytes(b"invalid CMS")
            (root / "app.plist").write_bytes(plistlib.dumps(self.signed))
            cli = {key: value for key, value in self.signed.items() if key != provisioning.GROUPS}
            (root / "cli.plist").write_bytes(plistlib.dumps(cli))

            def executable(path, body):
                path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
                path.chmod(0o755)

            executable(bin_dir / "xcodegen", "exit 0")
            executable(scripts / "xcbuild.sh", "exit 0")
            executable(bin_dir / "lipo", "echo arm64e")
            executable(
                bin_dir / "codesign",
                """case "$*" in
              *--verify*) exit 0 ;;
              *--entitlements*)
                case "${!#}" in *.app) cat app.plist ;; *) cat cli.plist ;; esac ;;
              *) printf 'flags=0x10000(runtime)\\nTeamIdentifier=TESTTEAM01\\n' ;;
            esac""",
            )
            for name in ["osascript", "pgrep", "ditto", "open"]:
                executable(bin_dir / name, "touch install-was-reached; exit 1")
            environment = dict(os.environ)
            environment["PATH"] = str(bin_dir) + os.pathsep + os.defpath
            result = subprocess.run(
                [shutil.which("just"), "install-app"],
                cwd=root,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
                timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Security verification failed: security failed", result.stderr)
            self.assertFalse((root / "install-was-reached").exists())


if __name__ == "__main__":
    unittest.main()
