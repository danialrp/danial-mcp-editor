#!/bin/bash
# Runs `swift <args>` for this package.
# With only the Command Line Tools installed (no Xcode), Swift Testing lives in a
# framework folder SwiftPM does not search, so the paths are added here.
#
# `test` runs in two steps unless --filter or --skip picks the tests: first
# everything else, then, alone and one at a time, the tests named `timed...`.
# They hold wall-clock limits, and beside the other suites they measure the
# queue for the GPU and CPU instead of the code (a 4K frame timed many
# times longer among them than alone).
set -euo pipefail
cd "$(dirname "$0")/.."

extra=()
dev="$(xcode-select -p 2>/dev/null || true)"
fw="$dev/Library/Developer/Frameworks"
if [[ "$dev" == *CommandLineTools* && -d "$fw" ]]; then
    # The Command Line Tools ship the Testing/Foundation cross-import overlay
    # without its module files, so cross-import overlays are turned off.
    extra=(-Xswiftc -F -Xswiftc "$fw"
           -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
           -Xlinker -F -Xlinker "$fw"
           -Xlinker -rpath -Xlinker "$fw")
fi

cmd="$1"; shift
run() { swift "$cmd" ${extra[@]+"${extra[@]}"} "$@"; }

split=false
if [[ "$cmd" == test ]]; then
    split=true
    for arg in "$@"; do
        case "$arg" in --filter*|--skip*|list|--list-tests|--help) split=false ;; esac
    done
fi
if ! $split; then
    run "$@"
    exit
fi

timed='/timed[A-Z]'
status=0
run "$@" --skip "$timed" || status=$?
echo "== timed tests, on their own"
alone=0
out="$(run "$@" --filter "$timed" --no-parallel 2>&1)" || alone=$?
printf '%s\n' "$out"
# A filter that matches nothing passes: that would drop the limits silently.
if ((alone == 0)) && ! grep -qE 'Test run with [1-9]' <<<"$out"; then
    echo "error: no timed test ran (tests named timed...)" >&2
    alone=1
fi
((status == 0)) || exit "$status"
exit "$alone"
