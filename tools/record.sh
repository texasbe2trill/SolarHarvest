#!/bin/zsh
# Records 60 frames (~20s at 0.35s apart) of a simulated activity cycling
# through every page, for building the animated GIF with make_gif.py.
# Requires CIQ_SDK_BIN and SOLAR_WORK - see cap.sh.
set -e
setopt no_nomatch   # a glob that matches nothing must not abort the run
: "${CIQ_SDK_BIN:?Set CIQ_SDK_BIN to your Connect IQ SDK's bin/ directory}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP=${SOLAR_WORK:-/tmp/solar-harvest-work}
mkdir -p "$SP"
cd "$ROOT"
cp source/SolarPowerView.mc "$SP/REC.orig"
python3 tools/patch_record.py
"$CIQ_SDK_BIN/monkeyc" -f monkey.jungle -o "$SP/rec.prg" -y developer_key -d fenix9prosolar51mm -w 2>&1 | grep -v SUCCESSFUL || true
cp "$SP/REC.orig" source/SolarPowerView.mc
echo "source restored"
pkill -f monkeydo 2>/dev/null || true
pkill -f "ConnectIQ.app/Contents/MacOS/simulator" 2>/dev/null || true
sleep 2
(nohup "$CIQ_SDK_BIN/connectiq" >/dev/null 2>&1 &)
sleep 7
(nohup "$CIQ_SDK_BIN/monkeydo" "$SP/rec.prg" fenix9prosolar51mm > "$SP/rec.log" 2>&1 &)
sleep 14
WID=$(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly|Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID):
    if 'Connect IQ Device Sim' in w.get('kCGWindowOwnerName',''): print(w.get('kCGWindowNumber')); break
")
rm -f "$SP"/frames/*.png 2>/dev/null || true
mkdir -p "$SP/frames"
for i in $(seq -w 1 60); do
  screencapture -x -o -l$WID "$SP/frames/f$i.png"
  sleep 0.35
done
echo "captured 60 frames"
