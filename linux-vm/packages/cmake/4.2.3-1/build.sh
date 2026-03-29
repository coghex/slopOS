#!/usr/bin/env bash
set -euo pipefail

./bootstrap --prefix="$PREFIX" --parallel="$BUILD_JOBS" -- \
  -DCMAKE_USE_OPENSSL:BOOL=OFF \
  -DBUILD_CursesDialog=OFF
make -j"$BUILD_JOBS"
