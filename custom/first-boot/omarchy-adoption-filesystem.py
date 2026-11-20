#!/usr/bin/env python3
"""Adoption filesystem operations anchored to non-symlink directory descriptors."""
import ctypes
import errno
import os
import stat
import sys
import uuid
from contextlib import contextmanager

DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def parts(path):
    result = path.split('/')
    if not result or any(p in ('', '.', '..') for p in result) or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError('invalid relative adoption path')
    return result


@contextmanager
def directory(root, components=(), create=False, owner=None):
    if not root.startswith('/'):
        raise ValueError('adoption root must be absolute')
    fd = os.open('/', DIRECTORY)
    try:
        for component in parts(root[1:]) + list(components):
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                    created = True
                except FileExistsError:
                    created = False
            child = os.open(component, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
            if create and created and owner is not None:
                os.fchown(fd, *owner)
                os.fchmod(fd, 0o755)
        yield fd
    finally:
        os.close(fd)


def exists(fd, name):
    try:
        return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def publish(src, name, dst, target):
    # Never overwrite a path concurrently created by the user.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    if rename(src, os.fsencode(name), dst, os.fsencode(target), 1) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), target)


def metadata(source, destination, owner):
    info = os.fstat(source)
    desired = owner or (info.st_uid, info.st_gid)
    current = os.fstat(destination)
    if (current.st_uid, current.st_gid) != desired:
        os.fchown(destination, *desired)
    os.fchmod(destination, stat.S_IMODE(info.st_mode))
    for key in os.listxattr(source):
        os.setxattr(destination, key, os.getxattr(source, key))
    os.utime(destination, ns=(info.st_atime_ns, info.st_mtime_ns))


def copy_entry(src, name, dst, target, owner=None):
    info = os.stat(name, dir_fd=src, follow_symlinks=False)
    if stat.S_ISLNK(info.st_mode):
        # Preserve leaf links verbatim; never traverse them.
        os.symlink(os.readlink(name, dir_fd=src), target, dir_fd=dst)
        desired = owner or (info.st_uid, info.st_gid)
        link = os.open(target, os.O_PATH | os.O_NOFOLLOW, dir_fd=dst)
        try:
            actual = os.fstat(link)
            if not stat.S_ISLNK(actual.st_mode):
                raise ValueError('adoption link replaced before metadata update')
            if (actual.st_uid, actual.st_gid) != desired:
                libc = ctypes.CDLL(None, use_errno=True)
                change = libc.fchownat
                change.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_int)
                if change(link, b'', *desired, 0x1000 | 0x100) != 0:  # AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW
                    code = ctypes.get_errno()
                    raise OSError(code, os.strerror(code))
        finally:
            os.close(link)
        return
    if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
        raise ValueError('special file refused in adoption snapshot')
    flags = DIRECTORY if stat.S_ISDIR(info.st_mode) else os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    source = os.open(name, flags, dir_fd=src)
    try:
        opened = os.fstat(source)
        if (info.st_dev, info.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError('adoption source changed during open')
        if stat.S_ISDIR(info.st_mode):
            os.mkdir(target, 0o700, dir_fd=dst)
            destination = os.open(target, DIRECTORY, dir_fd=dst)
        else:
            destination = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dst)
        try:
            if stat.S_ISDIR(info.st_mode):
                for entry in os.listdir(source):
                    copy_entry(source, entry, destination, entry, owner)
            else:
                while data := os.read(source, 1024 * 1024):
                    view = memoryview(data)
                    while view:
                        view = view[os.write(destination, view):]
            metadata(source, destination, owner)
        finally:
            os.close(destination)
    finally:
        os.close(source)


def remove_entry(fd, name):
    info = exists(fd, name)
    if info is None:
        return
    if stat.S_ISDIR(info.st_mode):
        child = os.open(name, DIRECTORY, dir_fd=fd)
        try:
            for entry in os.listdir(child):
                remove_entry(child, entry)
        finally:
            os.close(child)
        os.rmdir(name, dir_fd=fd)
    else:
        os.unlink(name, dir_fd=fd)


def copy_atomic(src, name, dst, target, owner=None):
    temporary = '.adoption-' + uuid.uuid4().hex
    try:
        copy_entry(src, name, dst, temporary, owner)
        publish(dst, temporary, dst, target)
    finally:
        remove_entry(dst, temporary)


def seed(src, dst, owner):
    for name in os.listdir(src):
        current = exists(dst, name)
        if current is None:
            copy_atomic(src, name, dst, name, owner)
        elif stat.S_ISDIR(current.st_mode):
            original = exists(src, name)
            if original is not None and stat.S_ISDIR(original.st_mode):
                left = os.open(name, DIRECTORY, dir_fd=src)
                try:
                    right = os.open(name, DIRECTORY, dir_fd=dst)
                    try:
                        seed(left, right, owner)
                    finally:
                        os.close(right)
                finally:
                    os.close(left)


def main(args):
    operation, root, relative, *rest = args
    components = parts(relative)
    if operation == 'mkdir':
        with directory(root, components, create=True, owner=tuple(map(int, rest))):
            pass
        return
    with directory(root, components[:-1]) as source:
        if operation == 'remove':
            remove_entry(source, components[-1])
            return
        target_root, target_relative, *owner = rest
        destination_parts = parts(target_relative)
        desired = tuple(map(int, owner)) if owner else None
        with directory(target_root, destination_parts[:-1], create=True) as destination:
            if operation == 'copy':
                copy_atomic(source, components[-1], destination, destination_parts[-1], desired)
            elif operation == 'move':
                try:
                    publish(source, components[-1], destination, destination_parts[-1])
                except OSError as error:
                    if error.errno != errno.EXDEV:
                        raise
                    copy_atomic(source, components[-1], destination, destination_parts[-1])
                    remove_entry(source, components[-1])
            elif operation == 'seed':
                left = os.open(components[-1], DIRECTORY, dir_fd=source)
                try:
                    right = os.open(destination_parts[-1], DIRECTORY, dir_fd=destination)
                    try:
                        seed(left, right, desired)
                    finally:
                        os.close(right)
                finally:
                    os.close(left)
            else:
                raise ValueError('unknown adoption operation')


if __name__ == '__main__':
    main(sys.argv[1:])
