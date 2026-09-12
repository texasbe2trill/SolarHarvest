"""Assemble the captured frames into a shareable loop, cropped to the watch face.

Usage: python3 make_gif.py <output.gif>
Reads frames from $SOLAR_WORK/frames (see record.sh).
"""
import glob, os, sys
from PIL import Image
import numpy as np

SP = os.environ.get('SOLAR_WORK', '/tmp/solar-harvest-work')

def disc(path):
    a = np.array(Image.open(path).convert('RGB')); h, w, _ = a.shape
    dark = (a.sum(2) < 100); rows = []
    for y in range(100, h - 80):
        xs = np.where(dark[y])[0]
        if len(xs) < 100: continue
        segs = np.split(xs, np.where(np.diff(xs) > 1)[0] + 1)
        seg = max(segs, key=len)
        if len(seg) > 200: rows.append((y, seg[0], seg[-1]))
    if not rows: return None
    ys = [r[0] for r in rows]; wide = max(rows, key=lambda r: r[2] - r[1])
    return ((wide[1] + wide[2]) // 2, (min(ys) + max(ys)) // 2, (wide[2] - wide[1]) // 2)

frames = sorted(glob.glob(f'{SP}/frames/f*.png'))
if not frames:
    sys.exit("no frames captured")

# One crop for the whole run: the window does not move, and re-detecting per
# frame would make the loop jitter.
box = None
for f in frames:
    d = disc(f)
    if d:
        cx, cy, r = d; r += 4
        box = (cx - r, cy - r, cx + r, cy + r)
        break
if box is None:
    sys.exit("could not locate the watch face")

imgs = []
blank = 0
for f in frames:
    im = Image.open(f).convert('RGB').crop(box).resize((300, 300), Image.LANCZOS)
    a = np.array(im)
    # Drop frames grabbed while the simulator was still starting or had crashed.
    if a.mean() < 4: blank += 1; continue
    if ((a[:, :, 2] > 120) & (a[:, :, 0] < 90) & (a[:, :, 1] < 140)).mean() > 0.05:
        blank += 1; continue
    imgs.append(im)

if len(imgs) < 10:
    sys.exit(f"only {len(imgs)} usable frames ({blank} rejected)")

out = sys.argv[1]
imgs[0].save(out, save_all=True, append_images=imgs[1:], duration=350, loop=0,
             optimize=True)
print(f"{out}: {len(imgs)} frames ({blank} rejected), {round(len(open(out,'rb').read())/1e6,2)} MB")
