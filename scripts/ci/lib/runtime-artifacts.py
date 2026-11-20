#!/usr/bin/env python3
"""Make receipts runner-owned without following links outside an artifact tree."""
import os
import stat
import sys


def normalize(tree, uid, gid):
    path = os.path.abspath(tree)
    if path == "/":
        raise ValueError("refusing the filesystem root as an artifact tree")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    root = os.open("/", flags)
    try:
        # Do not resolve symlinked ancestors, even when the leaf is a directory.
        for part in path.split("/")[1:]:
            child = os.open(part, flags, dir_fd=root)
            os.close(root)
            root = child
        device = os.fstat(root).st_dev

        def visit(fd):
            info = os.fstat(fd)
            if info.st_dev != device:
                raise ValueError("refusing to cross an artifact filesystem boundary")
            if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
                raise ValueError("refusing a hard-linked artifact")
            os.fchown(fd, uid, gid)
            access = 0o700 if stat.S_ISDIR(info.st_mode) else 0o600
            os.fchmod(fd, stat.S_IMODE(info.st_mode) | access)
            if not stat.S_ISDIR(info.st_mode):
                return
            for name in os.listdir(fd):
                entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if not (stat.S_ISREG(entry.st_mode) or stat.S_ISDIR(entry.st_mode)):
                    continue
                entry_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if stat.S_ISDIR(entry.st_mode):
                    entry_flags |= os.O_DIRECTORY
                child = os.open(name, entry_flags, dir_fd=fd)
                try:
                    opened = os.fstat(child)
                    if (opened.st_dev, opened.st_ino) != (entry.st_dev, entry.st_ino):
                        raise ValueError("artifact changed while opening it")
                    visit(child)
                finally:
                    os.close(child)

        visit(root)
    finally:
        os.close(root)


if __name__ == "__main__":
    normalize(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
