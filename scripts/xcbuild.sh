#!/usr/bin/env bash
# Runs xcodebuild, recovering once from Xcode 27's explicit-module scanner
# failure.
#
# The scanner cannot resolve the C shim modules of the NIO and MLX packages
# (CNIOPosix, CAsyncHTTPClient, _NumericsShims, ...) once a DerivedData
# directory has been written with a different build graph -- adding a target,
# switching scheme, or changing signing is enough. The failure is not
# repairable incrementally: every later build in that directory reports
# "Clang dependency scanning failure" or "missing required module" until the
# directory is removed. SWIFT_ENABLE_EXPLICIT_MODULES=NO in
# Configs/Project.xcconfig prevents new occurrences for the project's own
# targets but does not rescue an already-poisoned cache, and package targets do
# not read that xcconfig.
#
# Every invocation also passes -skipPackagePluginValidation: mlx-swift 0.31.5
# added a CudaBuild package plugin for Linux builds, and xcodebuild refuses to
# build any dependent target until a person approves the plugin in Xcode's UI.
# The plugin never runs on macOS.
#
# MACOSX_DEPLOYMENT_TARGET is forced to the app's floor for every target,
# packages included. Package manifests declare their own (older) floors, and a
# package whose floor is below macOS 13 (EventSource: 12.0) is compiled without
# class_ro_t pointer signing, which the linker then reports as a mismatch
# against every signed object in the app.
#
# Usage: scripts/xcbuild.sh <xcodebuild arguments ...>
set -euo pipefail

derived_data=""
previous=""
for argument in "$@"; do
    if [[ $previous == "-derivedDataPath" ]]; then
        derived_data="$argument"
    fi
    previous="$argument"
done

log_file="$(mktemp -t xcbuild)"
trap 'rm -f "$log_file"' EXIT

run_build() {
    # Stream output so a long build still shows progress, while keeping a copy
    # to classify the failure.
    set +e
    xcodebuild -skipPackagePluginValidation "$@" MACOSX_DEPLOYMENT_TARGET=26.0 2>&1 | tee "$log_file"
    local status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

if run_build "$@"; then
    exit 0
fi

if [[ -z $derived_data ]] ||
    ! grep -qE "Clang dependency scanning failure|missing required module" "$log_file"; then
    exit 1
fi

echo "xcbuild: stale module cache; clearing $derived_data and rebuilding" >&2
if command -v trash >/dev/null 2>&1; then
    trash "$derived_data"
else
    rm -rf "$derived_data"
fi
run_build "$@"
