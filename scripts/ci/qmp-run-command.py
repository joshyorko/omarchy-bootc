#!/usr/bin/env python3
"""Launch one command in the real GNOME guest's Alt+F2 dialog through QMP."""
import argparse
import json
from pathlib import Path
import socket
import time


def command_keys(command):
    if not command or len(command) > 512 or any(ord(c) < 32 or ord(c) > 126 for c in command):
        raise ValueError('expected a bounded printable ASCII command')
    plain = dict(zip(" -/.';\\", ('spc', 'minus', 'slash', 'dot', 'apostrophe', 'semicolon', 'backslash')))
    shifted = {':': 'semicolon', '|': 'backslash'}
    keys = [['alt', 'f2']]
    for character in command:
        if character.isascii() and (character.islower() or character.isdigit()):
            keys.append([character])
        elif character.isascii() and character.isupper():
            keys.append(['shift', character.lower()])
        elif character in plain:
            keys.append([plain[character]])
        elif character in shifted:
            keys.append(['shift', shifted[character]])
        else:
            raise ValueError(f'unsupported command character: {character!r}')
    return keys + [['ret']]


def send_keys(path, keys):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        stream = connection.makefile('rwb')
        if 'QMP' not in json.loads(stream.readline()):
            raise ValueError('missing QMP greeting')
        commands = [('qmp_capabilities', {})]
        commands += [('send-key', {'keys': [{'type': 'qcode', 'data': key} for key in chord],
                                   'hold-time': 60}) for chord in keys]
        for number, (command, arguments) in enumerate(commands):
            stream.write((json.dumps({'execute': command, 'arguments': arguments, 'id': number}) + '\n').encode())
            stream.flush()
            while True:
                response = json.loads(stream.readline())
                if response.get('id') == number:
                    if 'error' in response:
                        raise ValueError(response['error'])
                    break
            # Wait for the dialog to take focus before its first character.
            time.sleep(1 if number == 1 else 0.12)


def run_command(path, command):
    send_keys(path, command_keys(command))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket', type=Path)
    parser.add_argument('command')
    args = parser.parse_args()
    run_command(args.socket, args.command)
