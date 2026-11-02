import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JUST = shutil.which("just")
PRODUCTS = ".build/DerivedData-Release/Build/Products/Release"

FAKE_TOOL = """#!/usr/bin/python3
import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
with Path('events.jsonl').open('a') as output:
    output.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name in ('pgrep', 'open'):
    counter = Path(name + '.count')
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if name == 'pgrep':
        error = int(os.environ.get('FAKE_PGREP_ERROR', '0'))
        sys.exit(error or (0 if count <= int(os.environ.get('FAKE_RUNNING_CHECKS', '0')) else 1))
    sys.exit(1 if count <= int(os.environ.get('FAKE_OPEN_FAILURES', '0')) else 0)
if name == 'just' and sys.argv[1] == os.environ.get('FAKE_FAIL_RECIPE'):
    sys.exit(1)
"""


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="voice-install-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        shutil.copy2(ROOT / "justfile", self.root / "justfile")
        (self.root / PRODUCTS / "Voice.app").mkdir(parents=True)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake-tool"
        fake.write_text(FAKE_TOOL)
        fake.chmod(0o755)
        for name in [
            "just",
            "xcodegen",
            "pgrep",
            "osascript",
            "ditto",
            "codesign",
            "open",
            "sleep",
        ]:
            (self.bin / name).symlink_to(fake)
        (scripts / "xcbuild.sh").symlink_to(fake)

    def run_recipe(self, *arguments, **settings):
        environment = dict(os.environ)
        environment["PATH"] = str(self.bin) + os.pathsep + os.defpath
        environment.update(settings)
        result = subprocess.run(
            [JUST, *arguments],
            cwd=self.root,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
            timeout=10,
        )
        events = self.root / "events.jsonl"
        recorded = [json.loads(line) for line in events.read_text().splitlines()]
        return result, recorded

    def test_full_install_reuses_release_products_and_launches_last(self):
        prefix = "/tmp/quoted ' prefix/bin"
        result, events = self.run_recipe("install", prefix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            events,
            [
                ["just", "_install-app"],
                ["just", "_install-cli-products", PRODUCTS, prefix],
                ["just", "_install-notify-products", PRODUCTS, prefix],
                ["just", "_launch-installed-app"],
            ],
        )

    def test_copy_waits_for_the_exact_installed_app(self):
        result, events = self.run_recipe("_install-app", FAKE_RUNNING_CHECKS="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        names = [event[0] for event in events]
        self.assertLess(names.index("just"), names.index("osascript"))
        self.assertLess(names.index("osascript"), names.index("ditto"))
        self.assertNotIn("open", names)
        self.assertIn(
            ["osascript", "-e", 'tell application "/Applications/Voice.app" to quit'],
            events,
        )
        for event in events:
            if event[0] == "pgrep":
                self.assertEqual(event[1:4], ["-u", str(os.getuid()), "-f"])
                self.assertEqual(
                    event[4],
                    "^/Applications/Voice[.]app/Contents/MacOS/Voice([[:space:]]|$)",
                )

    def test_live_app_and_process_lookup_errors_prevent_copy(self):
        for settings, diagnostic in [
            ({"FAKE_RUNNING_CHECKS": "100"}, "Voice is still running"),
            ({"FAKE_PGREP_ERROR": "3"}, "cannot check whether"),
            ({"FAKE_FAIL_RECIPE": "_verify-security-path"}, ""),
        ]:
            with self.subTest(settings=settings):
                for name in ["events.jsonl", "pgrep.count"]:
                    (self.root / name).unlink(missing_ok=True)
                result, events = self.run_recipe("_install-app", **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertFalse(any(event[0] == "ditto" for event in events))

    def test_relaunch_retry_is_bounded_and_never_forces_a_new_instance(self):
        for failures, expected in [(2, 0), (100, 1)]:
            with self.subTest(failures=failures):
                for name in ["events.jsonl", "open.count"]:
                    (self.root / name).unlink(missing_ok=True)
                result, events = self.run_recipe(
                    "_launch-installed-app", FAKE_OPEN_FAILURES=str(failures)
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(
                    [event for event in events if event[0] == "open"],
                    [["open", "-a", "/Applications/Voice.app"]] * 3,
                )


if __name__ == "__main__":
    unittest.main()
