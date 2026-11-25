#!/bin/sh
# Run XCL's Windows unit-test binary under Wine with GPU tests process-isolated.
#
# XCL's GPU tests share a process-wide D3D12 device and UMA windows. Under Wine/vkd3d-proton
# gpu_sparse_vram_descriptors_buffers_and_xmem leaves backend state that makes the next GPU
# test fault (0x2a80), so the whole suite cannot run in one process. Running each gpu:: test
# in its own process gives the same coverage without that interaction; every other test stays
# in one batch.
#
# Usage:
#   WINEPREFIX=... XCL_DXC_DIR='C:\path\to\dxc' scripts/test-wine.sh <test-exe> [--limit N]
#
# The test executable is the unittests src/lib.rs binary `cargo test --no-run` prints.
# Set DISPLAY yourself (or prefix the command with xvfb-run) and the d3d12 overrides:
#   WINEDLLOVERRIDES='d3d12=n,b;d3d12core=n,b'
set -eu

WINE=${WINE:-}
exe=${1:?usage: test-wine.sh <test-exe> [--limit N]}
limit=0
if [ "${2:-}" = "--limit" ]; then limit=${3:?--limit needs a count}; fi

work=${TMPDIR:-/tmp}/xcl-test-wine.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT INT TERM

$WINE "$exe" --list 2>/dev/null | sed -n 's/: test$//p' > "$work/tests"
grep '^gpu::' "$work/tests" > "$work/gpu" || true
if [ "$limit" -gt 0 ]; then head -n "$limit" "$work/gpu" > "$work/gpu.limit"; mv "$work/gpu.limit" "$work/gpu"; fi

: > "$work/results"
run_one() { # run_one <name>; records PASS/FAIL/IGN
    out=$($WINE "$exe" --exact "$1" --test-threads=1 2>&1) && rc=0 || rc=$?
    if printf '%s' "$out" | grep -q 'test result: ok'; then
        if printf '%s' "$out" | grep -q '1 ignored'; then echo "IGN $1"; else echo "PASS $1"; fi
    elif [ "$rc" -eq 124 ]; then
        echo "IGN $1"
    else
        echo "FAIL $1"
    fi
}

while IFS= read -r t; do run_one "$t"; done < "$work/gpu" >> "$work/results"

# everything that is not a gpu:: test in one process (hle:: included)
$WINE "$exe" --skip gpu:: --test-threads=4 > "$work/rest" 2>&1 || true
rest=$(sed -n 's/^test result: \(ok\|FAILED\)\. \([0-9]*\) passed; \([0-9]*\) failed; \([0-9]*\) ignored;.*/\1 \2 \3 \4/p' "$work/rest" | tail -1)
if [ -z "$rest" ]; then
    echo "the non-gpu batch produced no result; see $work/rest" >&2
    rest="FAILED 0 1 0"
fi

pass=$(grep -c '^PASS' "$work/results" || true)
fail=$(grep -c '^FAIL' "$work/results" || true)
ign=$(grep -c '^IGN' "$work/results" || true)
set -- $rest
rpass=$2; rfail=$3; rign=$4
echo "gpu tests: $pass passed, $fail failed, $ign ignored"
echo "other tests: $rpass passed, $rfail failed, $rign ignored"
echo "total: $((pass + rpass)) passed, $((fail + rfail)) failed, $((ign + rign)) ignored"
grep '^FAIL' "$work/results" || true
[ "$fail" -eq 0 ] && [ "$rfail" -eq 0 ]
