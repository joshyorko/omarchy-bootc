#!/usr/bin/env python3
"""Capture the actual QEMU display as PNG through its local QMP socket."""
import argparse
import json
from pathlib import Path
import socket


def capture(qmp, output):
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(15)
        connection.connect(str(qmp))
        stream = connection.makefile("rwb")
        if "QMP" not in json.loads(stream.readline()):
            raise ValueError("missing QMP greeting")
        for number, (command, arguments) in enumerate((
            ("qmp_capabilities", {}),
            ("screendump", {"filename": str(output), "format": "png"}),
        )):
            stream.write((json.dumps({"execute": command, "arguments": arguments,
                                      "id": number}) + "\n").encode())
            stream.flush()
            while True:
                reply = json.loads(stream.readline())
                if reply.get("id") == number:
                    if "error" in reply:
                        raise ValueError(reply["error"])
                    break
    if output.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("QEMU did not produce a PNG")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("qmp", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    capture(args.qmp, args.output)
