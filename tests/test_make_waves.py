"""Exercise waveform-viewer selection without requiring a desktop in CI.

The real Makefile launches tiny viewer executables that record their VCD
argument. Simulation is assumed up to date so these tests isolate the
viewer boundary; the RTL regression exercises simulation separately.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MAKEFILE = Path(__file__).resolve().parents[1] / "Makefile"
MAKE = shutil.which("make")


class WaveViewerSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(MAKEFILE, self.root / "Makefile")
        for name in ("rtl/top", "tb", "model", "build", "bin"):
            (self.root / name).mkdir(parents=True)
        (self.root / "rtl/top/systolic_top.v").touch()
        (self.root / "tb/tb_systolic_top.v").touch()
        (self.root / "model/gen_vectors.py").touch()
        (self.root / "build/tb_systolic_top.vcd").write_text("$enddefinitions $end\n")
        self.env = os.environ.copy()
        for name in ("VIEWER", "MAKEFLAGS", "MFLAGS"):
            self.env.pop(name, None)
        # Do not inherit a developer's installed viewers. Supply only the
        # commands used by Make's discovery and recipe in this fixture.
        self.env["PATH"] = str(self.root / "bin")
        self.env["VIEWER_LOG"] = str(self.root / "viewer.log")
        for command in ("find", "basename", "dirname"):
            target = shutil.which(command)
            if target:
                (self.root / "bin" / command).symlink_to(target)

    def viewer(self, name):
        path = self.root / "bin" / name
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "{name}" "$@" > "$VIEWER_LOG"\n'
        )
        path.chmod(0o755)

    def run_waves(self, *assignments):
        return subprocess.run(
            [MAKE, "--no-print-directory", "--assume-old=sim-systolic_top",
             "waves", *assignments],
            cwd=self.root, env=self.env, capture_output=True, text=True,
            timeout=10,
        )

    def assert_viewer(self, expected, *assignments):
        result = self.run_waves(*assignments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "viewer.log").read_text().splitlines(),
            [expected, "build/tb_systolic_top.vcd"],
        )

    def test_surfer_only_opens_generated_waveform(self):
        self.viewer("surfer")
        self.assert_viewer("surfer")

    def test_gtkwave_is_preferred_when_both_are_available(self):
        self.viewer("gtkwave")
        self.viewer("surfer")
        self.assert_viewer("gtkwave")

    def test_explicit_viewer_override_is_respected(self):
        self.viewer("gtkwave")
        self.viewer("surfer")
        self.assert_viewer("surfer", "VIEWER=surfer")

    def test_viewer_arguments_are_preserved(self):
        self.viewer("surfer")
        result = self.run_waves("VIEWER=surfer --test-flag")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "viewer.log").read_text().splitlines(),
            ["surfer", "--test-flag", "build/tb_systolic_top.vcd"],
        )

    def test_missing_viewer_reports_setup_instructions(self):
        result = self.run_waves()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/setup.md", result.stdout + result.stderr)
        self.assertFalse((self.root / "viewer.log").exists())

    def test_quoted_viewer_path_with_spaces_is_respected(self):
        self.viewer("viewer with spaces")
        path = self.root / "bin" / "viewer with spaces"
        result = self.run_waves(f'VIEWER="{path}" --test-flag')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "viewer.log").read_text().splitlines(),
            ["viewer with spaces", "--test-flag", "build/tb_systolic_top.vcd"],
        )


if __name__ == "__main__":
    unittest.main()
