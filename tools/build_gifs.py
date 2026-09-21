"""Builds the animated store art: docs/store/hero-1440x720.gif and docs/store/cover-500x500.gif.

The Connect IQ developer dashboard takes a hero image of 1440 x 720 under 2048 KB and a cover image
of 500 x 500 under 300 KB, and both may be animated GIFs. These two show the field doing its job: a
replayed walk feeds it real solar readings, and it steps through its seven pages while the charts
fill in, the battery drains, and the sun moves.

Every frame of the watch is a simulator capture made by tools/film.py, which builds a copy of the
project with a scripted compute() (the same replay tools/patch_preview.py uses) and names every
screenshot for the step of the film it shows:

    python3 tools/film.py hero  fenix9prosolar51mm 16    # 280 px display, doubled by the capture to 560
    python3 tools/film.py cover fenix7s 8                # 240 px display, doubled to 480

    python3 tools/build_gifs.py hero  $SOLAR_WORK/film_hero  16
    python3 tools/build_gifs.py cover $SOLAR_WORK/film_cover 8

The last number is the steps each page stayed up, the same one the film was made with.

How the files stay small. One palette for the whole film. The background is reduced to that
palette once, and every frame is built on those exact pixels, so after the first frame the GIF
stores only the part of the dial that changed. Every background color lies on a single dusk ramp,
because a gradient that varies in two directions turns blotchy at 256 colors. Captures are
converted from the Mac display's color space to sRGB first, or every saturated color comes out
washed (the field's orange FF5500 reads as EC612A). The tool reads the finished file back,
compares every frame with what it meant to write, and stops with an error if the file is the
wrong size or over its limit.

Needs: pillow, numpy, macOS Avenir Next, and the Connect IQ device files.
"""
import hashlib
import io
import json
import pathlib
import re
import sys

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs' / 'store'
DEVICES = pathlib.Path.home() / 'Library/Application Support/Garmin/ConnectIQ/Devices'
AVENIR = '/System/Library/Fonts/Avenir Next.ttc'
WEIGHT = {'ultralight': 10, 'regular': 7, 'medium': 5, 'demi': 2, 'bold': 0, 'heavy': 8}
STOPS = [(0.00, (10, 16, 38)), (0.20, (28, 34, 78)), (0.38, (73, 45, 96)), (0.54, (140, 62, 92)),
         (0.68, (201, 96, 71)), (0.78, (238, 145, 62)), (0.855, (252, 194, 96))]
HORIZON, EARTH = 0.855, (9, 10, 15)
PAGES = 7
CLEAR = 255     # the palette number that means: leave what is there
CAPTIONS = ['SOLAR NOW  ·  LIVE SOLAR INTENSITY', 'FULL SUN  ·  TOTAL SUN YOU HAVE CAUGHT',
            'BATTERY  ·  LEVEL, DRAIN RATE, TIME LEFT', 'TO SUNSET  ·  DAYLIGHT YOU HAVE LEFT',
            'CATCHING  ·  HOW MUCH OF THE SUN REACHES YOU', 'SUN BONUS  ·  BATTERY TIME THE SUN ADDED',
            'COMPASS  ·  WHERE THE SUN IS']


def font(weight, size, scale):
    return ImageFont.truetype(AVENIR, int(size * scale), index=WEIGHT[weight])


def true_colors(shot):
    """A capture in sRGB. A screen capture is written in the Mac display's color space with that profile
    inside it. Colors within three counts of one of the watch's 64 are put back on it, so flat areas
    are truly flat and store in fewer bytes."""
    icc = shot.info.get('icc_profile')
    rgb = shot.convert('RGB')
    if icc:
        rgb = ImageCms.profileToProfile(rgb, ImageCms.ImageCmsProfile(io.BytesIO(icc)), ImageCms.createProfile('sRGB'),
                                        renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC, outputMode='RGB')
    a = np.asarray(rgb).astype(np.int16)
    grid = ((a + 42) // 85) * 85
    near = (np.abs(a - grid) <= 3).all(axis=2)
    a[near] = grid[near]
    return Image.fromarray(a.astype(np.uint8))


def display(capture, device):
    """The watch display out of a simulator window capture, at the capture's own pixels."""
    sim = json.loads((DEVICES / device / 'simulator.json').read_text())
    loc = sim['display']['location']
    art = Image.open(DEVICES / device / sim.get('image', device + '.png'))
    shot = true_colors(Image.open(capture))
    scale = shot.size[0] / art.size[0]
    top = (shot.size[1] - art.size[1] * scale) / 2
    x0, y0, d = loc['x'] * scale, top + loc['y'] * scale, loc['width'] * scale
    return shot.crop((round(x0), round(y0), round(x0 + d), round(y0 + d)))


def film(folder, device, side, per_page):
    """One dial for every step of the film's first pass through the seven pages: the last shot taken
    during that step, which is sure to show it. Returns [(page, dial)] in order."""
    last = {}
    for path in sorted(pathlib.Path(folder).glob('f_*_s*.png')):
        step = int(re.search(r'_s(\d+)\.png$', path.name).group(1))
        last[step] = path
    dials = []
    for step in sorted(last):
        if step >= PAGES * per_page:
            break
        face = display(last[step], device)
        if face.size != (side, side):
            face = face.resize((side, side), Image.NEAREST)
        dials.append((step // per_page, face))
    if len(set(page for page, _ in dials)) != PAGES:
        raise SystemExit('the captures in %s do not cover all %d pages' % (folder, PAGES))
    return dials


def sky_ramp(samples=4096):
    table = np.zeros((samples, 3), dtype=np.float64)
    ts = np.linspace(0.0, HORIZON, samples)
    for i in range(len(STOPS) - 1):
        a, ca = STOPS[i]
        b, cb = STOPS[i + 1]
        inside = (ts >= a) & (ts <= b)
        k = (ts[inside] - a) / (b - a)
        k = k * k * (3 - 2 * k)
        for j in range(3):
            table[inside, j] = ca[j] + (cb[j] - ca[j]) * k
    return table


def ramp_colors(count, upto=HORIZON):
    """Colors at even steps of color along the dusk ramp, so each has a near neighbor to dither with."""
    table = sky_ramp()[: max(2, int(4096 * upto / HORIZON))]
    along = np.concatenate([[0.0], np.cumsum(np.sqrt((np.diff(table, axis=0) ** 2).sum(axis=1)))])
    at = np.interp(np.linspace(0.0, along[-1], count), along, np.arange(len(table)))
    colors = []
    for i in at:
        c = tuple(int(v) for v in np.rint(table[int(round(i))]))
        if c not in colors:
            colors.append(c)
    return colors


def nearest(img, colors):
    """Each pixel's nearest of `colors`, exactly. Pillow's own mapping to a palette is approximate."""
    a = np.asarray(img.convert('RGB'), dtype=np.int32)
    packed = (a[..., 0] << 16) | (a[..., 1] << 8) | a[..., 2]
    uniq, inverse = np.unique(packed, return_inverse=True)
    rgb = np.stack([(uniq >> 16) & 255, (uniq >> 8) & 255, uniq & 255], axis=1)
    pal = np.asarray(colors, dtype=np.int32)
    index = np.empty(len(rgb), dtype=np.uint8)
    for at in range(0, len(rgb), 4096):
        d = ((rgb[at:at + 4096, None, :] - pal[None, :, :]) ** 2).sum(axis=2)
        index[at:at + 4096] = d.argmin(axis=1)
    return index[inverse.reshape(-1)].reshape(a.shape[:2])


def as_palette(colors):
    pal = Image.new('P', (1, 1))
    flat = [v for c in colors for v in c]
    pal.putpalette(flat + list(colors[0]) * (256 - len(colors)))
    return pal


def dial_colors(dials, count):
    """The watch's own colors exactly where the dials use them, then the blends that smooth an edge."""
    side = dials[0].size[0]
    picks = dials[:: max(1, len(dials) // 20)] + [dials[-1]]
    sheet = Image.new('RGB', (side * len(picks), side))
    for i, f in enumerate(picks):
        sheet.paste(f, (i * side, 0))
    values, counts = np.unique(np.asarray(sheet).reshape(-1, 3), axis=0, return_counts=True)
    on_grid = sorted(((int(k), tuple(int(v) for v in c)) for c, k in zip(values, counts)
                      if all(int(v) % 85 == 0 for v in c) and k >= 40), reverse=True)
    exact = [c for _, c in on_grid][:48]
    rest = max(8, count - len(exact))
    blends = sheet.quantize(colors=rest, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE, kmeans=2).getpalette()[:rest * 3]
    return exact + [tuple(blends[i:i + 3]) for i in range(0, len(blends), 3)]


def reduce_ground(smooth, still, sky, words):
    """The background as palette numbers: the smooth part dithered to the sky's colors alone, the drawn
    part (lettering, bezel) set in undithered from the sky's colors and the words' together."""
    dithered = np.asarray(smooth.quantize(palette=as_palette(sky), dither=Image.Dither.FLOYDSTEINBERG)).copy()
    dithered[dithered >= len(sky)] = 0
    drawn = (np.asarray(still, dtype=np.int16) != np.asarray(smooth, dtype=np.int16)).any(axis=2)
    dithered[drawn] = nearest(still, sky + words)[drawn]
    return dithered


def word_colors(smooth, still, extra, count):
    a, b = np.asarray(still, dtype=np.int16), np.asarray(smooth, dtype=np.int16)
    drawn = a[(a != b).any(axis=2)]
    for strip, under in extra:
        s, u = np.asarray(strip, dtype=np.int16), np.asarray(under, dtype=np.int16)
        drawn = np.concatenate([drawn, s[(s != u).any(axis=2)]])
    img = Image.fromarray(drawn.astype(np.uint8).reshape(1, -1, 3))
    flat = img.quantize(colors=count, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE, kmeans=3).getpalette()[:count * 3]
    return [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]


def save(out, frames, durations, size, limit):
    out.parent.mkdir(parents=True, exist_ok=True)
    # A step on which nothing on the dial moved is not a frame of its own: the one before it stays up
    # longer. (Pillow would merge them anyway; doing it here keeps the check below exact.)
    kept, held = [], []
    for frame, ms in zip(frames, durations):
        if kept and frame.tobytes() == kept[-1].tobytes():
            held[-1] += ms
        else:
            kept.append(frame)
            held.append(ms)
    frames, durations = kept, held
    # A pixel that did not change since the frame before is written as "see through": a run of those
    # costs a GIF next to nothing, and what is on screen is the same. Palette number 255 is kept free
    # for it.
    written, before = [frames[0]], np.asarray(frames[0])
    for frame in frames[1:]:
        now = np.asarray(frame)
        delta = now.copy()
        delta[now == before] = CLEAR
        img = Image.fromarray(delta, 'P')
        img.putpalette(frames[0].getpalette())
        written.append(img)
        before = now
    written[0].save(out, save_all=True, append_images=written[1:], duration=durations, loop=0, optimize=False,
                    disposal=1, transparency=CLEAR)
    with Image.open(out) as gif:
        assert gif.size == size, gif.size
        assert gif.n_frames == len(frames), (gif.n_frames, len(frames))
        for i in range(gif.n_frames):
            gif.seek(i)
            got = np.asarray(gif.convert('RGB'), dtype=np.int16)
            want = np.asarray(frames[i].convert('RGB'), dtype=np.int16)
            assert int(np.abs(got - want).max()) == 0, 'frame %d reads back differently' % i
    nbytes = out.stat().st_size
    if nbytes >= limit:
        raise SystemExit('%s is %d bytes: the limit is %d' % (out.name, nbytes, limit))
    print('%s  %dx%d  %d frames  %.1f s a loop  %d bytes (%.0f KB)' % (
        out.relative_to(ROOT), size[0], size[1], len(frames), sum(durations) / 1000.0, nbytes, nbytes / 1024.0))


def compose(ground_p, pal, colors, dials, origin, side, under, captions=None):
    """Every frame: the reduced background with this step's dial set into it (and its caption)."""
    big = Image.new('L', (side * 4, side * 4), 0)
    ImageDraw.Draw(big).ellipse([2, 2, side * 4 - 3, side * 4 - 3], fill=255)
    mask = big.resize((side, side), Image.LANCZOS)
    covered = mask.point(lambda v: 255 if v > 0 else 0)
    frames = []
    for k, dial in enumerate(dials):
        region = under.copy()
        region.paste(dial, (0, 0), mask)
        frame = ground_p.copy()
        if captions is not None:
            strip, box = captions[k]
            frame.paste(Image.fromarray(strip, 'P'), box)
        frame.paste(Image.fromarray(nearest(region, colors), 'P'), origin, covered)
        frame.putpalette(pal.getpalette())
        frames.append(frame)
    return frames


def hero(folder, per_page=16):
    W, H, D, CX, CY, BEZEL, S = 1440, 720, 560, 1092, 350, 15, 2
    device = 'fenix9prosolar51mm'
    steps = film(folder, device, D, per_page)
    table = sky_ramp()
    ys = (np.arange(H)[:, None] + 0.5) / H
    xs = (np.arange(W)[None, :] + 0.5) / W
    m = np.clip((xs - 0.30) / (0.66 - 0.30), 0, 1)
    m = m * m * (3 - 2 * m)
    t = ys * (0.16 + 0.84 * m)
    px, py = xs * W, ys * H
    dist = np.sqrt((px - CX) ** 2 + (py - CY) ** 2)
    t = t + 0.085 * np.exp(-(((px - CX) / 430.0) ** 2 + ((py - 0.80 * H) / 200.0) ** 2)) * m
    ro = D // 2 + BEZEL
    t = t - 0.16 * np.exp(-((dist - ro) / 26.0) ** 2) * (dist >= ro - 2)
    t = np.clip(t, 0.0, HORIZON - 1e-6)
    sky = table[np.minimum((t / HORIZON * (len(table) - 1)).astype(np.int64), len(table) - 1)]
    sky[(ys >= HORIZON)[:, 0], :, :] = EARTH
    img = Image.fromarray(np.clip(np.rint(sky), 0, 255).astype(np.uint8)).resize((W * S, H * S), Image.BICUBIC)
    smooth = img.copy()
    d = ImageDraw.Draw(img, 'RGBA')
    d.line([(0, int(H * S * HORIZON)), (W * S, int(H * S * HORIZON))], fill=(255, 206, 150, 55), width=max(1, int(1.2 * S)))

    def tracked(x, y, text, fnt, fill, track=0.0):
        for ch in text:
            d.text((x, y), ch, font=fnt, fill=fill)
            x += d.textlength(ch, font=fnt) + track * S
        return x

    def wrap(text, fnt, width):
        words, lines, line = text.split(), [], ''
        for word in words:
            trial = (line + ' ' + word).strip()
            if d.textlength(trial, font=fnt) <= width:
                line = trial
            else:
                lines.append(line)
                line = word
        return lines + ([line] if line else [])

    M, COL = 96 * S, 560 * S
    warm, white, soft, dim = (255, 209, 138), (255, 255, 255), (223, 226, 235), (183, 189, 203)
    y = 78 * S
    tracked(M, y, 'SOLAR', font('ultralight', 80, S), white, track=5.5)
    y += 88 * S
    tracked(M, y, 'HARVEST', font('demi', 80, S), warm, track=3.0)
    y += 114 * S
    tracked(M, y, 'FREE DATA FIELD', font('medium', 17, S), warm, track=6.0)
    y += 44 * S
    d.line([(M, y), (M + 108 * S, y)], fill=(255, 209, 138, 150), width=max(1, int(1.4 * S)))
    y += 28 * S
    for line in wrap('See what the sun is really adding to your battery, live, during any activity.', font('regular', 24, S), COL):
        d.text((M, y), line, font=font('regular', 24, S), fill=soft)
        y += 35 * S
    y += 24 * S
    for point in ['Real battery drain and solar gain, measured on your own watch.',
                  '7 pages: live solar, full-sun time, battery, time to sunset, sky conditions, sun bonus, and a sun compass.',
                  'Alerts when you enter shade, when sunset is near, and when the sun is charging your battery.']:
        for line in wrap(point, font('regular', 17, S), COL):
            d.text((M, y), line, font=font('regular', 17, S), fill=dim)
            y += 25 * S
        y += 12 * S
    foot = font('regular', 13, S)
    for row, devices in enumerate([['fenix 9 Pro Solar', 'fenix 8 Solar', 'fenix 7 Solar', 'fenix 6 Pro Solar'],
                                   ['Enduro 3', 'Enduro 2', 'tactix', 'quatix', 'Forerunner 955 Dual Power']]):
        x, yf = M, H * S - (68 - 23 * row) * S
        for i, name in enumerate(devices):
            d.text((x, yf), name, font=foot, fill=(126, 132, 148))
            x += d.textlength(name, font=foot)
            if i != len(devices) - 1:
                d.text((x + 11 * S, yf), '·', font=foot, fill=(80, 86, 101))
                x += 25 * S
    R = D // 2
    d.ellipse([(CX - ro) * S, (CY - ro) * S, (CX + ro) * S, (CY + ro) * S], fill=(14, 15, 21, 255))
    d.ellipse([(CX - ro) * S, (CY - ro) * S, (CX + ro) * S, (CY + ro) * S], outline=(255, 224, 182, 150), width=int(2 * S))
    d.ellipse([(CX - R - 2) * S, (CY - R - 2) * S, (CX + R + 2) * S, (CY + R + 2) * S], outline=(58, 54, 50, 255), width=int(2 * S))
    smooth, still = smooth.resize((W, H), Image.LANCZOS), img.resize((W, H), Image.LANCZOS)

    box = (CX - 300, CY + ro + 8, CX + 300, CY + ro + 32)

    def caption(text):
        strip = still.crop(box).resize(((box[2] - box[0]) * S, (box[3] - box[1]) * S), Image.LANCZOS)
        cd = ImageDraw.Draw(strip)
        fnt = font('medium', 12.5, S)
        track = 2.2 * S
        width = sum(cd.textlength(ch, font=fnt) + track for ch in text) - track
        x = ((box[2] - box[0]) * S - width) / 2
        for ch in text:
            cd.text((x, 5 * S), ch, font=fnt, fill=(214, 200, 178))
            x += cd.textlength(ch, font=fnt) + track
        return strip.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS)

    strips = [caption(c) for c in CAPTIONS]
    sky_c = ramp_colors(108)
    if EARTH not in sky_c:
        sky_c.append(EARTH)
    words = [c for c in word_colors(smooth, still, [(s, still.crop(box)) for s in strips], 50) if c not in sky_c]
    for c in ((255, 255, 255), (255, 209, 138), (14, 15, 21)):
        if c not in sky_c + words:
            words.append(c)
    dials = [f for _, f in steps]
    colors = sky_c + words
    for c in dial_colors(dials, 255 - len(colors)):
        if c not in colors and len(colors) < 255:
            colors.append(c)
    pal = as_palette(colors)
    ground = Image.fromarray(reduce_ground(smooth, still, sky_c, words), 'P')
    ground.putpalette(pal.getpalette())
    strips_p = [nearest(s, sky_c + words) for s in strips]
    pages = [page for page, _ in steps]
    frames = compose(ground, pal, colors, dials, (CX - R, CY - R), D, still.crop((CX - R, CY - R, CX + R, CY + R)),
                     captions=[(strips_p[p], box[:2]) for p in pages])
    durations = []
    for k, page in enumerate(pages):
        first = k == 0 or pages[k - 1] != page
        durations.append(650 if first else 120)
    durations[-1] = 900
    save(OUT / 'hero-1440x720.gif', frames, durations, (W, H), 2_000_000)


def cover(folder, per_page=8):
    SIDE, D = 500, 480
    device = 'fenix7s'
    steps = film(folder, device, D, per_page)
    table = sky_ramp()
    t = (np.arange(SIDE) + 0.5) / SIDE * 0.80
    rows = table[np.minimum((t / HORIZON * (len(table) - 1)).astype(int), len(table) - 1)]
    smooth = Image.fromarray(np.clip(np.rint(np.repeat(rows[:, None, :], SIDE, axis=1)), 0, 255).astype(np.uint8))
    S = 4
    big = smooth.resize((SIDE * S, SIDE * S), Image.BICUBIC)
    d = ImageDraw.Draw(big, 'RGBA')
    c, r = SIDE * S // 2, (D // 2) * S
    d.ellipse([c - r - 7 * S, c - r - 7 * S, c + r + 7 * S, c + r + 7 * S], fill=(14, 15, 21, 255))
    d.ellipse([c - r - 7 * S, c - r - 7 * S, c + r + 7 * S, c + r + 7 * S], outline=(255, 224, 182, 170), width=int(1.5 * S))
    still = big.resize((SIDE, SIDE), Image.LANCZOS)
    sky_c = ramp_colors(36, upto=0.80)
    words = [c for c in ((14, 15, 21), (255, 224, 182), (134, 120, 101)) if c not in sky_c]
    dials = [f for _, f in steps]
    colors = sky_c + words
    for col in dial_colors(dials, 100 - len(colors)):
        if col not in colors and len(colors) < 100:
            colors.append(col)
    pal = as_palette(colors)
    ground = Image.fromarray(reduce_ground(smooth, still, sky_c, words), 'P')
    ground.putpalette(pal.getpalette())
    x0 = (SIDE - D) // 2
    frames = compose(ground, pal, colors, dials, (x0, x0), D, still.crop((x0, x0, x0 + D, x0 + D)))
    pages = [page for page, _ in steps]
    durations = []
    for k, page in enumerate(pages):
        first = k == 0 or pages[k - 1] != page
        durations.append(700 if first else 160)
    durations[-1] = 900
    save(OUT / 'cover-500x500.gif', frames, durations, (SIDE, SIDE), 290_000)


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ('hero', 'cover'):
        raise SystemExit(__doc__)
    extra = [int(sys.argv[3])] if len(sys.argv) == 4 else []
    (hero if sys.argv[1] == 'hero' else cover)(sys.argv[2], *extra)
