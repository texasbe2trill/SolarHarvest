#!/bin/zsh
# Design preview harness: one page, one background theme, on the primary
# review device (fenix 9 Pro Solar 51mm). Restarts the simulator for every
# capture, since a run that crashed leaves it pinned on its crash screen and
# every later capture would show that instead of the build under test.
#
# Usage: preview.sh <page_number> <light|dark|auto> <output.png>
# Requires CIQ_SDK_BIN and SOLAR_WORK - see cap.sh.
set -e
setopt no_nomatch
: "${CIQ_SDK_BIN:?Set CIQ_SDK_BIN to your Connect IQ SDK's bin/ directory}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP=${SOLAR_WORK:-/tmp/solar-harvest-work}
mkdir -p "$SP"
cd "$ROOT"
PAGE=$1; BG=$2; OUT=$3
cp source/SolarPowerView.mc "$SP/PV.orig"
python3 tools/patch_preview.py "$PAGE" "$BG" >/dev/null
"$CIQ_SDK_BIN/monkeyc" -f monkey.jungle -o "$SP/pv.prg" -y developer_key -d fenix9prosolar51mm -w 2>&1 | grep -v SUCCESSFUL || true
cp "$SP/PV.orig" source/SolarPowerView.mc
pkill -f monkeydo 2>/dev/null || true
pkill -f "ConnectIQ.app/Contents/MacOS/simulator" 2>/dev/null || true
sleep 2
(nohup "$CIQ_SDK_BIN/connectiq" >/dev/null 2>&1 &)
sleep 7
(nohup "$CIQ_SDK_BIN/monkeydo" "$SP/pv.prg" fenix9prosolar51mm > "$SP/pv.log" 2>&1 &)
sleep 13
WID=$(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly|Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID):
    if 'Connect IQ Device Sim' in w.get('kCGWindowOwnerName',''): print(w.get('kCGWindowNumber')); break
")
screencapture -x -o -l$WID $OUT
echo "captured page $PAGE"
