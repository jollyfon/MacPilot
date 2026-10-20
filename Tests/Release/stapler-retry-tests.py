#!/usr/bin/env python3
"""Isolated regression tests for the network-only macOS stapler retry helper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "Scripts" / "stapler-retry.sh"
TRANSIENT_CLOUDKIT_ERROR = (
    'error is Error Domain=NSURLErrorDomain Code=-1005 '
    '"The network connection was lost." UserInfo={...}\n'
    "CloudKit's response is inconsistent with expections: (null)\n"
    "The staple and validate action failed! Error 68.\n"
)


FAKE_XCRUN = r'''#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["STAPLER_CALL_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
with open(os.environ["STAPLER_RESPONSES"], encoding="utf-8") as stream:
    responses = json.load(stream)
with open(os.environ["STAPLER_CALL_LOG"], encoding="utf-8") as stream:
    call_number = sum(1 for line in stream if line.strip()) - 1
response = responses[min(call_number, len(responses) - 1)]
sys.stdout.write(response.get("stdout", ""))
sys.stderr.write(response.get("stderr", ""))
sys.exit(response["status"])
'''


FAKE_SLEEP = r'''#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["STAPLER_SLEEP_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
'''


class StaplerRetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.zsh = shutil.which("zsh")
        if cls.zsh is None:
            raise unittest.SkipTest("zsh is required to source the production helper")

    def run_stapler(self, action: str, responses: list[dict[str, object]]) -> tuple[
        subprocess.CompletedProcess[str], list[list[str]], list[list[str]], str
    ]:
        with tempfile.TemporaryDirectory(prefix="macpilot stapler retry ") as temp:
            temp_path = Path(temp)
            fake_bin = temp_path / "fake bin"
            fake_bin.mkdir()
            for name, contents in (("xcrun", FAKE_XCRUN), ("sleep", FAKE_SLEEP)):
                executable = fake_bin / name
                executable.write_text(contents, encoding="utf-8")
                executable.chmod(0o755)

            response_path = temp_path / "responses.json"
            response_path.write_text(json.dumps(responses), encoding="utf-8")
            call_log = temp_path / "xcrun-calls.jsonl"
            sleep_log = temp_path / "sleep-calls.jsonl"
            target = temp_path / "signed app bundle" / "MacPilot.app"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "STAPLER_RESPONSES": str(response_path),
                    "STAPLER_CALL_LOG": str(call_log),
                    "STAPLER_SLEEP_LOG": str(sleep_log),
                }
            )
            result = subprocess.run(
                [
                    self.zsh,
                    "-c",
                    'set -euo pipefail; source "$1"; macpilot_stapler "$2" "$3"',
                    "stapler-retry-test",
                    str(HELPER),
                    action,
                    str(target),
                ],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            calls = self.read_json_lines(call_log)
            sleeps = self.read_json_lines(sleep_log)
            return result, calls, sleeps, str(target)

    @staticmethod
    def read_json_lines(path: Path) -> list[list[str]]:
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_successCallsStaplerOnceWithoutSleeping(self) -> None:
        for action in ("staple", "validate"):
            with self.subTest(action=action):
                result, calls, sleeps, target = self.run_stapler(
                    action, [{"status": 0, "stdout": "ok\n"}]
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [["stapler", action, target]])
                self.assertEqual(sleeps, [])

    def testTransientCloudKitFailureRetriesStapleAndValidateWithExactArguments(self) -> None:
        for action in ("staple", "validate"):
            with self.subTest(action=action):
                result, calls, sleeps, target = self.run_stapler(
                    action,
                    [
                        {"status": 68, "stderr": TRANSIENT_CLOUDKIT_ERROR},
                        {"status": 0, "stdout": "ticket accepted\n"},
                    ],
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [["stapler", action, target]] * 2)
                self.assertEqual(sleeps, [["10"]])

    def testTwoTransientFailuresUseTenThenThirtySecondBackoff(self) -> None:
        result, calls, sleeps, target = self.run_stapler(
            "validate",
            [
                {"status": 68, "stderr": TRANSIENT_CLOUDKIT_ERROR},
                {"status": 68, "stderr": TRANSIENT_CLOUDKIT_ERROR},
                {"status": 0},
            ],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["stapler", "validate", target]] * 3)
        self.assertEqual(sleeps, [["10"], ["30"]])

    def testNonTransientFailuresFailImmediatelyWithOriginalStatus(self) -> None:
        failures = (
            {"status": 68, "stderr": "Error Domain=NSPOSIXErrorDomain Code=-1005\nError 68"},
            {"status": 68, "stderr": "signature invalid: Error 68"},
            {"status": 68, "stderr": "Error Domain=NSURLErrorDomain Code=-1004\nError 68"},
            {"status": 68, "stderr": "Error Domain=NSURLErrorDomain Code=-10050\nError 68"},
        )
        for response in failures:
            with self.subTest(response=response):
                result, calls, sleeps, target = self.run_stapler("staple", [response])
                self.assertEqual(result.returncode, response["status"], result.stderr)
                self.assertEqual(calls, [["stapler", "staple", target]])
                self.assertEqual(sleeps, [])

    def testExhaustedTransientRetriesReturnFinalStaplerStatus(self) -> None:
        result, calls, sleeps, target = self.run_stapler(
            "staple",
            [{"status": 68, "stderr": TRANSIENT_CLOUDKIT_ERROR}] * 6,
        )
        self.assertEqual(result.returncode, 68, result.stderr)
        self.assertEqual(calls, [["stapler", "staple", target]] * 6)
        self.assertEqual(sleeps, [["10"], ["30"], ["60"], ["120"], ["180"]])

    def testReleaseCallersKeepStaplingValidationAndSignatureChecksWired(self) -> None:
        distribute = (REPO_ROOT / "Scripts" / "distribute-app.sh").read_text(
            encoding="utf-8"
        )
        build_dmg = (REPO_ROOT / "Scripts" / "build-dmg.sh").read_text(
            encoding="utf-8"
        )
        for script in (distribute, build_dmg):
            self.assertIn('source "$ROOT/Scripts/stapler-retry.sh"', script)
            self.assertIn('macpilot_stapler staple ', script)
            self.assertIn('macpilot_stapler validate ', script)
        self.assertIn('codesign --verify --deep --strict "$APP"', distribute)
        self.assertIn('verify-signing-requirement.sh', distribute)
        self.assertIn('codesign --verify --deep --strict "$APP"', build_dmg)
        self.assertIn('codesign --force --sign "${MACPILOT_DEVELOPER_ID:?}"', build_dmg)
        self.assertIn('macpilot_stapler validate "$DMG"', build_dmg)


if __name__ == "__main__":
    unittest.main(verbosity=2)
