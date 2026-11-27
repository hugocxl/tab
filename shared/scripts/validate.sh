#!/bin/bash
# The validation every change must pass: a warnings-as-errors build and the
# tests on the Mac. The iOS build of this package runs in ../ios/scripts/validate.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
mkdir -p build/validation
swift build --build-tests -Xswiftc -warnings-as-errors 2>&1 | tee build/validation/build.log | tail -20
swift test --skip-build 2>&1 | tee build/validation/test.log | tail -20
echo "shared: validation passed"
