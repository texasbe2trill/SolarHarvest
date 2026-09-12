"""Tile a set of simulator screenshots into a grid, auto-cropped to each watch
face (works from a plain screenshot of the whole simulator window - no manual
cropping needed).

Usage: python3 build_page_sheet.py <output.png> <columns> <page1.png> <page2.png> ...
"""
import sys
from PIL import Image
import numpy as np

def disc(path):
    a = np.array(Image.open(path).convert('RGB')); h, w, _ = a.shape
    dark = (a.sum(2) < 100); rows = []
    for y in range(100, h - 80):
        xs = np.where(dark[y])[0]
        if len(xs) < 100:
            continue
        d = np.diff(xs); segs = np.split(xs, np.where(d > 1)[0] + 1)
        seg = max(segs, key=len)
        if len(seg) > 200:
            rows.append((y, seg[0], seg[-1]))
    if not rows:
        return None
    ys = [r[0] for r in rows]
    wide = max(rows, key=lambda r: r[2] - r[1])
    return ((wide[1] + wide[2]) // 2, (min(ys) + max(ys)) // 2, (wide[2] - wide[1]) // 2)

def build(paths, out, cols, tile=300, pad=10, bg=(18, 18, 22)):
    tiles = []
    for p in paths:
        d = disc(p)
        im = Image.open(p).convert('RGB')
        if d:
            cx, cy, r = d
            r += 6
            im = im.crop((cx - r, cy - r, cx + r, cy + r))
        tiles.append(im.resize((tile, tile), Image.LANCZOS))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * tile + (cols + 1) * pad, rows * tile + (rows + 1) * pad), bg)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet.paste(t, (pad + c * (tile + pad), pad + r * (tile + pad)))
    sheet.save(out)
    print("wrote", out, sheet.size)

if __name__ == "__main__":
    out, cols = sys.argv[1], int(sys.argv[2])
    build(sys.argv[3:], out, cols)
