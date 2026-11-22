#!/usr/bin/env python3
"""Exercise the real serial/QMP client and guest command guard, without a VM."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "poweroff", ROOT / "scripts/ci/poweroff-interactive-vm.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PoweroffTests(unittest.TestCase):
    def test_guest_command_guard(self):
        source = (ROOT / "scripts/ci/export-interactive-vm.sh").read_text()
        guard = source.split("        stty -F /dev/ttyS1 -echo\n", 1)[1].split("        exit 0", 1)[0]
        with tempfile.TemporaryDirectory(prefix="codex-vm-control-", dir="/tmp") as temp:
            control, receipt, called = [Path(temp) / name for name in ("control", "receipt", "called")]
            for command, expected in (("OMARCHY_INTERACTIVE_POWEROFF", 0), ("unexpected", 1)):
                control.write_text(command + "\n")
                called.unlink(missing_ok=True)
                script = "systemctl() { printf '%s\\n' \"$*\" >\"$CALLED\"; }; " + guard.replace("/dev/ttyS1", '"$CONTROL"').replace("/dev/ttyS0", '"$RECEIPT"')
                result = subprocess.run(["bash", "-eu", "-c", script], env=dict(
                    os.environ, CONTROL=str(control), RECEIPT=str(receipt), CALLED=str(called)))
                self.assertEqual(result.returncode, expected)
                self.assertEqual(called.exists(), expected == 0)
                if expected == 0:
                    self.assertEqual(called.read_text(), "poweroff --no-block\n")
                    self.assertIn("POWEROFF_REQUESTED", receipt.read_text())

    def test_qmp_evidence(self):
        for event, succeeds in (
            ({"event": "SHUTDOWN", "data": {"guest": True, "reason": "guest-shutdown"}}, True),
            ({"event": "SHUTDOWN", "data": {"guest": False, "reason": "host-qmp-quit"}}, False),
            ({"event": "STOP"}, False),
        ):
            with self.subTest(event=event), tempfile.TemporaryDirectory(prefix="codex-qmp-control-", dir="/tmp") as temp:
                qmp, control = str(Path(temp) / "qmp"), str(Path(temp) / "control")
                errors = []
                with socket.socket(socket.AF_UNIX) as server, socket.socket(socket.AF_UNIX) as commands:
                    server.bind(qmp); server.listen(1); server.settimeout(2)
                    commands.bind(control); commands.listen(1); commands.settimeout(2)

                    def serve():
                        try:
                            with server.accept()[0] as connection:
                                connection.settimeout(2)
                                stream = connection.makefile("rwb")
                                stream.write(b'{"QMP":{}}\n'); stream.flush()
                                self.assertEqual(json.loads(stream.readline())["execute"], "qmp_capabilities")
                                stream.write(b'{"return":{},"id":1}\n'); stream.flush()
                                with commands.accept()[0] as command:
                                    command.settimeout(2)
                                    self.assertEqual(command.makefile("rb").readline(), b"OMARCHY_INTERACTIVE_POWEROFF\n")
                                stream.write((json.dumps(event) + "\n").encode()); stream.flush()
                        except BaseException as error:
                            errors.append(error)

                    worker = threading.Thread(target=serve)
                    worker.start()
                    try:
                        if succeeds:
                            self.assertEqual(MODULE.poweroff(qmp, control, timeout=2), event)
                        else:
                            with self.assertRaises((ValueError, TimeoutError)):
                                MODULE.poweroff(qmp, control, timeout=2)
                    finally:
                        worker.join(3)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
