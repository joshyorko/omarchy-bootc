#!/usr/bin/env bash

set -xeuo pipefail

BOOTC_REVISION="${BOOTC_REVISION:?}"
BOOTC_SOURCE="${BOOTC_SOURCE:?}"

git init .
git remote add origin "${BOOTC_SOURCE}"
git fetch --depth 1 origin "${BOOTC_REVISION}"
git checkout --detach FETCH_HEAD
[[ "$(git rev-parse HEAD)" == "${BOOTC_REVISION}" ]]

make bin install-all DESTDIR=/output
