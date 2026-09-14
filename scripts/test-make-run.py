"""Exercise the real Make recipes without launching an app or compiling code."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class MakeRunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="crate build test ")
        self.addCleanup(self.temporary.cleanup)
        self.checkout = Path(self.temporary.name).resolve()
        shutil.copyfile(
            Path(__file__).resolve().parents[1] / "Makefile",
            self.checkout / "Makefile",
        )
        self.app = (
            self.checkout
            / "build-output/DerivedData/Build/Products/Debug/CrateAgent.app"
        )
        self.capture = self.checkout / "opened-path"
        fixture_home_directory = tempfile.TemporaryDirectory(prefix="crate-home-", dir="/private/tmp")
        self.addCleanup(fixture_home_directory.cleanup)
        self.fixture_home = Path(fixture_home_directory.name)
        stale_app = (
            self.fixture_home
            / "Library/Developer/Xcode/DerivedData/CrateAgent-old"
            / "Build/Products/Debug/CrateAgent.app"
        )
        stale_app.mkdir(parents=True)
        binaries = self.checkout / "bin"
        binaries.mkdir()
        opener = binaries / "open"
        opener.write_text('#!/bin/bash\nprintf "%s" "$1" > "$CAPTURE_PATH"\n')
        opener.chmod(0o755)
        self.environment = dict(
            os.environ,
            PATH=f"{binaries}:{os.environ['PATH']}",
            CAPTURE_PATH=str(self.capture),
        )

    def run_make(self, *arguments):
        return subprocess.run(
            ["make", f"HOME={self.fixture_home}", *arguments],
            cwd=self.checkout,
            env=self.environment,
            text=True,
            capture_output=True,
        )

    def test_run_opens_current_checkout_build_with_spaces_in_path(self):
        self.app.mkdir(parents=True)
        result = self.run_make("run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.capture.read_text(), str(self.app))

    def test_missing_build_fails_without_opening_another_checkout(self):
        result = self.run_make("run")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())
        self.assertIn("make build", result.stdout)

    def test_build_uses_same_derived_data_directory(self):
        result = self.run_make("-n", "build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f'-derivedDataPath "{self.checkout}/build-output/DerivedData"',
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
