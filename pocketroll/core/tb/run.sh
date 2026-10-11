#!/usr/bin/env bash
# Run the core-side checks for pocketroll_recycle.v:
#
#   node         -> recycle_model.js, the cycle-accurate JS model of the FSM
#   iverilog+vvp -> pocketroll_recycle_tb.v, the self-checking Verilog testbench
#
# Any failure exits non-zero (the testbench ends with $fatal on a mismatch or a
# timeout). Build products go to a temporary directory, nothing is written here.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/scoop/apps/iverilog/current/bin:$PATH"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo "== recycle_model.js =="
node tb/recycle_model.js

echo; echo "== pocketroll_recycle (iverilog) =="
iverilog -g2012 -o "$out/rc_tb.vvp" pocketroll_recycle.v tb/pocketroll_recycle_tb.v
vvp -n "$out/rc_tb.vvp"

echo; echo "done."
