#!/bin/zsh
# Screenshot a single page on a single device via the Connect IQ simulator.
# Usage: cap.sh <device_id> <page_number> <output.png>
#
# Requires:
#   CIQ_SDK_BIN  - path to your Connect IQ SDK's bin/ directory
#   SOLAR_WORK   - scratch directory for build artifacts (defaults to /tmp/solar-harvest-work)
# macOS + pyobjc (`pip install pyobjc-framework-Quartz`) for window capture.
set -e
setopt no_nomatch   # a glob that matches nothing must not abort the run
: "${CIQ_SDK_BIN:?Set CIQ_SDK_BIN to your Connect IQ SDK's bin/ directory}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP=${SOLAR_WORK:-/tmp/solar-harvest-work}
mkdir -p "$SP"
cd "$ROOT"
DEV=$1; PAGE=$2; OUT=$3
cp source/SolarPowerView.mc "$SP/PV.orig"
python3 tools/patch_preview.py "$PAGE" Graphics.COLOR_BLACK >/dev/null
"$CIQ_SDK_BIN/monkeyc" -f monkey.jungle -o "$SP/pv.prg" -y developer_key -d $DEV -w 2>&1 | grep -v SUCCESSFUL || true
cp "$SP/PV.orig" source/SolarPowerView.mc
pkill -f monkeydo 2>/dev/null || true
pkill -f "ConnectIQ.app/Contents/MacOS/simulator" 2>/dev/null || true
sleep 2
(nohup "$CIQ_SDK_BIN/connectiq" >/dev/null 2>&1 &)
sleep 7
(nohup "$CIQ_SDK_BIN/monkeydo" "$SP/pv.prg" $DEV > "$SP/pv.log" 2>&1 &)
sleep 13
WID=$(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly|Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID):
    if 'Connect IQ Device Sim' in w.get('kCGWindowOwnerName',''): print(w.get('kCGWindowNumber')); break
")
screencapture -x -o -l$WID $OUT
echo "captured $DEV page $PAGE"
