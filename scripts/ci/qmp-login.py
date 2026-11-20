#!/usr/bin/env python3
"""Type a disposable test password into the actual QEMU greeter, once."""
import argparse
import json
from pathlib import Path
import re
import socket
import time


def login(path, password):
    if not re.fullmatch(r'[a-z0-9]{1,64}', password):
        raise ValueError('fixture password must contain lowercase ASCII letters/digits only')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        stream = connection.makefile('rwb')
        if 'QMP' not in json.loads(stream.readline()):
            raise ValueError('missing QMP greeting')
        commands = [('qmp_capabilities', {})]
        commands += [('send-key', {'keys': [{'type': 'qcode', 'data': key}], 'hold-time': 60})
                     for key in [*password, 'ret']]
        for number, (command, arguments) in enumerate(commands):
            stream.write((json.dumps({'execute': command, 'arguments': arguments, 'id': number})+'\n').encode())
            stream.flush()
            while True:
                response = json.loads(stream.readline())
                if response.get('id') == number:
                    if 'error' in response:
                        raise ValueError(response['error'])
                    break
            time.sleep(0.12)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket', type=Path)
    parser.add_argument('password')
    args = parser.parse_args()
    login(args.socket, args.password)
