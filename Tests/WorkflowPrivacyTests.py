"""Exercise the actual live workflow command blocks with harmless fake commands."""

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class WorkflowPrivacyTests(unittest.TestCase):
    def test_live_checks_keep_output_private_and_preserve_failure(self):
        workflow = (ROOT / ".github/workflows/live-tests.yml").read_text()
        self.assertNotIn("uses: actions/upload-artifact", workflow)
        self.assertNotIn("inputs.reason", workflow)
        for name, log in [
            ("Run the live WindowServer suite", "spaceo-live-command.log"),
            ("Run the full computer-use conformance matrix", "spaceo-computer-use-command.log"),
        ]:
            block = re.search(r"      - name: " + re.escape(name)
                              + r"\n(.*?)(?=\n      - name:|\Z)", workflow, re.S)[1]
            body = re.search(r"        run: \|\n((?:          .*\n|\n)+)", block)[1]
            command = textwrap.dedent(body)
            for status in (0, 1):
                with self.subTest(step=name, status=status), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    tools = root / "bin"
                    tools.mkdir()
                    for tool in ("bash", "make"):
                        stub = tools / tool
                        stub.write_text('#!/bin/sh\necho PRIVATE_FIXTURE_OUTPUT\n'
                                        'echo PRIVATE_FIXTURE_ERROR >&2\nexit "$FIXTURE_STATUS"\n')
                        stub.chmod(0o700)
                    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                               RUNNER_TEMP=directory, FIXTURE_STATUS=str(status))
                    result = subprocess.run(["/bin/bash", "-c", command], env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, status)
                    self.assertNotIn("PRIVATE_FIXTURE", result.stdout + result.stderr)
                    retained = root / log
                    self.assertIn("PRIVATE_FIXTURE_OUTPUT", retained.read_text())
                    self.assertIn("PRIVATE_FIXTURE_ERROR", retained.read_text())
                    self.assertEqual(retained.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
