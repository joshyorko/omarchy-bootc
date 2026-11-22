#!/usr/bin/env python3
"""Request clean test-guest shutdown over private serial; verify QMP evidence."""
import json
import socket
import sys
import time


def poweroff(qmp, control, timeout=120):
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(qmp)
        stream = connection.makefile("rwb")
        if "QMP" not in json.loads(stream.readline()):
            raise ValueError("missing QMP greeting")
        stream.write(b'{"execute":"qmp_capabilities","id":1}\n')
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if reply.get("id") == 1:
                if "error" in reply:
                    raise ValueError(reply["error"])
                break
        with socket.socket(socket.AF_UNIX) as command:
            command.settimeout(timeout)
            command.connect(control)
            channel = command.makefile("rwb")
            print("Waiting for guest serial control READY", file=sys.stderr)
            if channel.readline() != b"OMARCHY_CONTROL_READY\n":
                raise ValueError("missing guest control READY")
            channel.write(b"OMARCHY_INTERACTIVE_POWEROFF\n")
            channel.flush()
            if channel.readline() != b"OMARCHY_CONTROL_ACK\n":
                raise ValueError("missing guest control acknowledgement")
            print("Guest acknowledged shutdown; waiting for QMP SHUTDOWN", file=sys.stderr)
            # Retain the UART backend until the guest has consumed the command
            # and shut down. An immediate socket hangup can discard pending RX.
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("no guest shutdown event")
                connection.settimeout(remaining)
                reply = json.loads(stream.readline())
                if reply.get("event") == "SHUTDOWN":
                    if reply.get("data", {}).get("guest") is not True:
                        raise ValueError("shutdown was not requested by the guest")
                    return reply


if __name__ == "__main__":
    print(json.dumps(poweroff(sys.argv[1], sys.argv[2])))
