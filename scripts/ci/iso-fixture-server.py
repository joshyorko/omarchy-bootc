#!/usr/bin/env python3
"""Serve the disposable ISO fixture and retain bounded, untrusted launcher logs."""
import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading


class Handler(SimpleHTTPRequestHandler):
    log_lock = threading.Lock()

    def __init__(self, *args, evidence, **kwargs):
        self.evidence = evidence
        super().__init__(*args, **kwargs)

    def do_POST(self):
        if self.path != '/launcher-log':
            self.send_error(404)
            return
        try:
            size = int(self.headers.get('Content-Length', ''))
        except ValueError:
            self.send_error(400)
            return
        if not 0 <= size <= 256 * 1024:
            self.send_error(413)
            return
        self.connection.settimeout(5)
        body = self.rfile.read(size)
        if len(body) != size:
            self.send_error(400)
            return
        # A fixed diagnostics-only destination, never a guest-provided path.
        # Its contents cannot satisfy the root guest completion/digest gates.
        with self.log_lock:
            log = self.evidence / 'live-launcher.log'
            previous = log.read_bytes() if log.exists() else b''
            # Concurrent late snapshots must not erase an earlier exit/error.
            log.write_bytes((previous + body)[-1024 * 1024:])
        self.send_response(204)
        self.end_headers()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('web', type=Path)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    handler = functools.partial(Handler, directory=str(args.web), evidence=args.evidence)
    with ThreadingHTTPServer(('127.0.0.1', 18763), handler) as server:
        server.serve_forever()
