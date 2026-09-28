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
    def test_retained_publication_is_atomic_and_refuses_moved_tag(self):
        workflow = (ROOT / ".github/workflows/publish-retained.yml").read_text()
        block = workflow.split("      - name: Publish verified assets and scope together\n", 1)[1]
        command = textwrap.dedent(block.split("        run: |\n", 1)[1])
        for moved in (False, True):
            with self.subTest(moved=moved), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                tools = root / "bin"
                tools.mkdir()
                notes = "Hosting Viewer inside a SpaceO virtual display is unsupported"
                (root / "spaceo-release-notes.md").write_text(notes)
                stub = tools / "gh"
                stub.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if args[0] == 'api':
    print(os.environ['MOCK_REMOTE_TAG'])
elif args[:2] == ['release', 'create']:
    assert '--notes-file' in args and '--generate-notes' not in args
    notes = pathlib.Path(args[args.index('--notes-file') + 1]).read_text()
    assert 'Hosting Viewer inside a SpaceO virtual display is unsupported' in notes
    assert len([a for a in args if '/spaceo-release-candidate/' in a]) == 5
    pathlib.Path(os.environ['RUNNER_TEMP'], 'published').touch()
else:
    sys.exit(2)
''')
                stub.chmod(0o700)
                env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                           RUNNER_TEMP=directory, GITHUB_REPOSITORY="ParthJadhav/SpaceO",
                           SPACEO_RELEASE_TAG_OBJECT="expected",
                           MOCK_REMOTE_TAG="moved" if moved else "expected")
                result = subprocess.run(["/bin/bash", "-c", command], env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, not moved, result.stderr)
                self.assertEqual((root / "published").exists(), not moved)

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
