"""Builds the Connect IQ Store icon for Solar Harvest, and the device icons.

docs/store/icon-500.png            500 x 500, no text, a real ground, clear of the edge
docs/store/device-icon-128-*.png   128 x 128 in each screen palette, for the app store on
                                   the watch: 64 colours for every watch this field ships to,
                                   16, 8 and 2 for any other slot the dashboard shows

The picture is the field's own: the sun low on its day arc, solid where it has
been and dotted where it is still to go, over a horizon, and a solar panel on
the ground lit where the sun lands, on the golden hour sky of the hero.
Everything renders at 4x and downsamples so the arc and the cells keep clean
edges.

Usage: python3 tools/build_icon.py   (from the repository root)
Needs: pillow, numpy.
"""
import math
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs' / 'store'
S = 4
SIZE = 500 * S

STOPS = [(0.00, (12, 22, 48)), (0.20, (28, 34, 78)), (0.38, (73, 45, 96)), (0.54, (140, 62, 92)),
         (0.68, (201, 96, 71)), (0.78, (238, 145, 62)), (0.855, (252, 194, 96))]
HORIZON = 0.72
GROUND = (14, 17, 34)


def ramp(t):
    for i in range(len(STOPS) - 1):
        a, ca = STOPS[i]
        b, cb = STOPS[i + 1]
        if a <= t <= b:
            k = (t - a) / (b - a)
            k = k * k * (3 - 2 * k)
            return tuple(int(ca[j] + (cb[j] - ca[j]) * k) for j in range(3))
    return STOPS[-1][1]


def art(stroke=3.2):
    """The icon at 4x. stroke is the arc's width in icon pixels: thin for the
    500 px store icon, thicker for the 128 px device icon where a thin arc
    would dither away."""
    # The sky, the horizon at 72 percent of the height, and a little grain so
    # the gradient does not band.
    rows = np.array([ramp(min(1.0, y / (SIZE * HORIZON) * 0.855)) for y in range(SIZE)], dtype=np.int16)
    sky = np.repeat(rows[:, None, :], SIZE, axis=1)
    sky = np.clip(sky + np.random.default_rng(3).integers(-3, 4, (SIZE, SIZE, 1)), 0, 255).astype(np.uint8)
    img = Image.fromarray(sky)
    hy = int(SIZE * HORIZON)
    cx, sun_y = SIZE // 2, int(SIZE * 0.50)

    # The sun's glow, before the disc and the ground so it warms the sky only.
    glow = Image.new('RGB', (SIZE, SIZE), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for rad, v in [(230, 22), (160, 32), (105, 46), (62, 70), (38, 110)]:
        gd.ellipse([cx - rad * S, sun_y - rad * S, cx + rad * S, sun_y + rad * S], fill=(v, int(v * 0.74), int(v * 0.38)))
    glow = glow.filter(ImageFilter.GaussianBlur(40 * S))
    img = Image.fromarray(np.clip(np.asarray(img).astype(int) + np.asarray(glow).astype(int), 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img, 'RGBA')

    # The ground, and the panel on it: five cells, the middle ones lit by the
    # sun above them, the outer ones only outlined.
    d.rectangle([0, hy, SIZE, SIZE], fill=GROUND + (255,))
    d.line([(0, hy), (SIZE, hy)], fill=(255, 214, 160, 120), width=max(1, int(1.6 * S)))
    cell_w, cell_h, gap = 56 * S, 42 * S, 10 * S
    total = 5 * cell_w + 4 * gap
    x0 = cx - total // 2
    top = hy + 30 * S
    for i in range(5):
        x = x0 + i * (cell_w + gap)
        near = 1.0 - abs(i - 2) / 2.6
        fill = (255, 170, 0, int(40 + 215 * near ** 2))
        d.rounded_rectangle([x, top, x + cell_w, top + cell_h], radius=4 * S, fill=fill,
                            outline=(255, 214, 160, 200), width=max(1, int(1.4 * S)))
        # The cell's own gridline, the panel's signature from the launcher icon.
        d.line([(x + cell_w // 2, top + 4 * S), (x + cell_w // 2, top + cell_h - 4 * S)],
               fill=(GROUND[0], GROUND[1], GROUND[2], 150), width=max(1, int(1.2 * S)))

    # The day arc: from the left horizon over the top to the right horizon,
    # solid behind the sun, dotted ahead of it. The sun sits past noon.
    rr = int(SIZE * 0.36)
    acx, acy = cx, hy
    def pt(deg):
        a = math.radians(deg)
        return (acx + rr * math.cos(a), acy - rr * math.sin(a))
    sun_deg = 62.0
    for i in range(0, 1000):
        t0 = 174 - i * 0.17
        if t0 < 6:
            break
        p0, p1 = pt(t0), pt(t0 - 0.17)
        if t0 > sun_deg:
            near = (174 - t0) / (174 - sun_deg)
            a = int(60 + 150 * near ** 1.4)
            d.line([p0, p1], fill=(255, 229, 183, a), width=int(stroke * S))
        elif (i % 12) < 5:
            gone = (sun_deg - t0) / (sun_deg - 6)
            d.line([p0, p1], fill=(255, 238, 208, int(200 - 90 * gone)), width=int(stroke * S))
    sx, sy = [int(v) for v in pt(sun_deg)]
    sr = int(30 * S)
    d.ellipse([sx - sr - 9 * S, sy - sr - 9 * S, sx + sr + 9 * S, sy + sr + 9 * S], outline=(255, 228, 178, 110), width=int((stroke * 0.6) * S))
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 246, 226, 255))
    return img


PALETTES = {
    '64colors': [(r, g, b) for r in (0, 85, 170, 255) for g in (0, 85, 170, 255) for b in (0, 85, 170, 255)],
    '16colors': [(255, 255, 255), (170, 170, 170), (85, 85, 85), (0, 0, 0), (255, 0, 0), (170, 0, 0),
                 (255, 85, 0), (255, 170, 0), (0, 255, 0), (0, 170, 0), (0, 170, 255), (0, 0, 255),
                 (170, 0, 255), (255, 0, 255), (0, 255, 255), (85, 85, 0)],
    '8colors': [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
                (255, 0, 255), (0, 255, 255)],
    '2colors': [(0, 0, 0), (255, 255, 255)],
}


def simple_art(sky, ground, ink, sun, lit, dim):
    """The same picture in flat colours for the small palettes: a thick arc,
    the sun, the horizon and three cells, drawn at 4x for clean edges."""
    img = Image.new('RGB', (SIZE, SIZE), sky)
    d = ImageDraw.Draw(img)
    hy = int(SIZE * HORIZON)
    d.rectangle([0, hy, SIZE, SIZE], fill=ground)
    d.line([(0, hy), (SIZE, hy)], fill=ink, width=8 * S)
    cx = SIZE // 2
    rr = int(SIZE * 0.36)
    def pt(deg):
        a = math.radians(deg)
        return (cx + rr * math.cos(a), hy - rr * math.sin(a))
    sun_deg = 62.0
    for i in range(0, 1000):
        t0 = 174 - i * 0.17
        if t0 < 6:
            break
        if t0 > sun_deg or (i % 24) < 10:
            d.line([pt(t0), pt(t0 - 0.17)], fill=ink, width=12 * S)
    sx, sy = [int(v) for v in pt(sun_deg)]
    sr = 34 * S
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=sun)
    cell_w, cell_h, gap = 80 * S, 50 * S, 16 * S
    x0 = cx - (3 * cell_w + 2 * gap) // 2
    top = hy + 36 * S
    for i in range(3):
        x = x0 + i * (cell_w + gap)
        d.rectangle([x, top, x + cell_w, top + cell_h], fill=(lit if i == 1 else dim), outline=ink, width=6 * S)
    return img


def device_icons(big):
    small = art(stroke=9.0).resize((128, 128), Image.LANCZOS).convert('RGB')
    flat = {
        '16colors': simple_art((85, 85, 85), (0, 0, 0), (255, 255, 255), (255, 255, 255), (255, 170, 0), (85, 85, 0)),
        '8colors': simple_art((0, 0, 0), (0, 0, 0), (255, 255, 255), (255, 255, 0), (255, 255, 0), (0, 0, 0)),
        '2colors': simple_art((0, 0, 0), (0, 0, 0), (255, 255, 255), (255, 255, 255), (255, 255, 255), (0, 0, 0)),
    }
    written = []
    for name, colours in PALETTES.items():
        icon = small if name == '64colors' else flat[name].resize((128, 128), Image.LANCZOS)
        pal = Image.new('P', (1, 1))
        flat_pal = [c for rgb in colours for c in rgb]
        pal.putpalette(flat_pal + [0] * (768 - len(flat_pal)))
        dither = Image.Dither.FLOYDSTEINBERG if name == '64colors' else Image.Dither.NONE
        out = icon.quantize(palette=pal, dither=dither).convert('RGB')
        path = OUT / f'device-icon-128-{name}.png'
        out.save(path, optimize=True)
        written.append(path)
    return written


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    big = art()
    path = OUT / 'icon-500.png'
    big.resize((500, 500), Image.LANCZOS).save(path, optimize=True)
    print(path.relative_to(ROOT), path.stat().st_size // 1024, 'KB')
    for p in device_icons(big):
        print(p.relative_to(ROOT), p.stat().st_size, 'bytes')
