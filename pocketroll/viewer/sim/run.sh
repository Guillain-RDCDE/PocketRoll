#!/usr/bin/env bash
# Regenerate the (synthetic, privacy-safe) test vectors from the reference model,
# then run the Verilog testbenches under Icarus Verilog.
#
#   node  → viewer_model.js emits tb_cartram.hex / tb_sta.hex / tb_fb_expected.hex
#   iverilog+vvp → simulate gbcam_photo_decode and gbcam_sta_locate against them
#
# The model also cross-checks our decode against MugDump's gbcam.js on a real .sta
# IF those local files exist (env: MUGDUMP_GBCAM, REAL_STA); otherwise it's skipped
# and only the self-contained synthetic tests run. No personal data is committed.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/scoop/apps/iverilog/current/bin:$PATH"

echo "== reference model + vectors =="
node viewer_model.js

echo; echo "== gbcam_photo_decode =="
iverilog -g2012 -o pd.vvp ../rtl/gbcam_photo_decode.v tb_photo_decode.v
vvp pd.vvp

echo; echo "== gbcam_sta_locate =="
iverilog -g2012 -o sl.vvp ../rtl/gbcam_sta_locate.v tb_sta_locate.v
vvp sl.vvp

echo; echo "done."
