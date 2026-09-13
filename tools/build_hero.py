"""Builds docs/hero-1440x720.png.

A golden hour sky with the sun on its own arc: solid where it has already
travelled, dotted where it still has to go, which is the same convention the
compass page draws on the watch. Everything renders at 2x and downsamples, so
the type and the arc keep clean edges, and the sky carries a little grain
because a gradient this large bands without it.

Usage: python3 tools/build_hero.py   (run from the repository root)
Needs: pillow, numpy, and macOS Avenir Next.
"""
import math
import pathlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2
W, H = 1440 * S, 720 * S
AVENIR = '/System/Library/Fonts/Avenir Next.ttc'
IDX = {'ultralight': 10, 'regular': 7, 'medium': 5, 'demi': 2, 'bold': 0, 'heavy': 8}
def font(w, size): return ImageFont.truetype(AVENIR, int(size * S), index=IDX[w])

STOPS = [(0.00,(12,22,48)),(0.20,(28,34,78)),(0.38,(73,45,96)),(0.54,(140,62,92)),
         (0.68,(201,96,71)),(0.78,(238,145,62)),(0.855,(252,194,96))]
HORIZON, GROUND = 0.855, (9,10,15)

def ramp(t):
    if t >= HORIZON: return GROUND
    for i in range(len(STOPS)-1):
        a,ca = STOPS[i]; b,cb = STOPS[i+1]
        if a <= t <= b:
            k=(t-a)/(b-a); k=k*k*(3-2*k)
            return tuple(int(ca[j]+(cb[j]-ca[j])*k) for j in range(3))
    return STOPS[-1][1]

# 1. sky
rows = np.array([ramp(y/H) for y in range(H)], dtype=np.int16)
sky = np.repeat(rows[:, None, :], W, axis=1)
rng = np.random.default_rng(7)
sky = np.clip(sky + rng.integers(-3, 4, (H, W, 1)), 0, 255).astype(np.uint8)
img = Image.fromarray(sky)

# 2. left scrim, before the sun so it never dims it
xs = np.arange(W)/W
plateau, fade = 0.40, 0.72
k = np.clip((fade - xs) / (fade - plateau), 0, 1); k = k*k*(3-2*k)
scrim = np.repeat((247*k).astype(np.uint8)[None,:], H, axis=0)
img.paste(Image.new('RGB',(W,H),(6,8,14)), (0,0), Image.fromarray(scrim))

# 3. the sun's path, then its glow, then the disc
cx, cy, rr = int(W*0.46), int(H*1.02), int(H*0.80)
def arc_pt(deg):
    a = math.radians(deg); return (cx + rr*math.cos(a), cy - rr*math.sin(a))
SUN_DEG = 69.0
sun_x, sun_y = [int(v) for v in arc_pt(SUN_DEG)]

glow = Image.new('RGB', (W,H), (0,0,0))
gd = ImageDraw.Draw(glow)
for rad, v in [(360,26),(250,34),(165,44),(100,58),(58,96)]:
    gd.ellipse([sun_x-rad*S, sun_y-rad*S, sun_x+rad*S, sun_y+rad*S],
               fill=(v, int(v*0.74), int(v*0.38)))
glow = glow.filter(ImageFilter.GaussianBlur(62*S))
img = Image.fromarray(np.clip(np.asarray(img).astype(int) + np.asarray(glow).astype(int), 0, 255).astype(np.uint8))

d = ImageDraw.Draw(img, 'RGBA')
# The travelled half fades as it recedes, so the path emerges out of the sky
# instead of cutting across the copy. The half still to come stays dotted.
for i in range(420):
    t0 = 150 - i*0.34
    if t0 < 30: break
    p0, p1 = arc_pt(t0), arc_pt(t0-0.28)
    if t0 > SUN_DEG:
        near = (150 - t0) / (150 - SUN_DEG)        # 0 far behind, 1 at the sun
        a = int(14 + 74 * (near ** 1.7))
        d.line([p0,p1], fill=(255,229,183,a), width=int(2.0*S))
    elif i % 7 < 3:
        gone = (SUN_DEG - t0) / (SUN_DEG - 30)     # fades toward the horizon
        a = int(118 - 52 * gone)
        d.line([p0,p1], fill=(255,238,208,a), width=int(2.0*S))

sr = int(19*S)
d.ellipse([sun_x-sr,sun_y-sr,sun_x+sr,sun_y+sr], fill=(255,246,226,255))
d.ellipse([sun_x-sr-6*S,sun_y-sr-6*S,sun_x+sr+6*S,sun_y+sr+6*S], outline=(255,228,178,95), width=int(1.5*S))

# 4. ground
hy = int(H*HORIZON)
d.rectangle([0,hy,W,H], fill=(9,10,15,255))
d.line([(0,hy),(W,hy)], fill=(255,206,150,55), width=max(1,int(1.2*S)))

# ---------- type ----------
def tracked(draw, xy, text, fnt, fill, track=0.0):
    x, y = xy
    for ch in text:
        draw.text((x,y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + track*S
    return x
def tracked_w(draw, text, fnt, track=0.0):
    return sum(draw.textlength(c, font=fnt) + track*S for c in text)
def wrap(draw, text, fnt, maxw):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur+' '+w).strip()
        if draw.textlength(t, font=fnt) <= maxw: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

M, COLW = 96*S, 648*S
f_title_l, f_title_b = font('ultralight',84), font('demi',84)
f_tag, f_body = font('regular',25), font('regular',17)
f_cap, f_foot = font('medium',13), font('regular',13)
WARM, WHITE, SOFT, DIM = (255,209,138), (255,255,255), (223,226,235), (183,189,203)

y = 118*S
tracked(d, (M,y), 'SOLAR', f_title_l, WHITE, track=5.5); y += 92*S
tracked(d, (M,y), 'HARVEST', f_title_b, WARM, track=3.0); y += 126*S
d.line([(M,y),(M+108*S,y)], fill=(255,209,138,150), width=max(1,int(1.4*S))); y += 30*S
for ln in wrap(d,'Know what the sun is actually giving back to your watch.',f_tag,COLW):
    d.text((M,y), ln, font=f_tag, fill=SOFT); y += 37*S
y += 30*S
for pt in ['Battery gain measured from your own watch, not a marketing constant.',
           'Seven pages. Sun path, daylight window, harvest, drain and the bonus it bought.',
           'Alerts for shade, sunset, and the moment solar starts outrunning your drain.']:
    for ln in wrap(d, pt, f_body, COLW):
        d.text((M,y), ln, font=f_body, fill=DIM); y += 25*S
    y += 13*S

# ---------- faces ----------
ROOT = pathlib.Path(__file__).resolve().parent.parent
faces = [(ROOT/'docs/store/preview-1.png', 'LIVE INTENSITY'),
         (ROOT/'docs/store/preview-7.png', 'WHERE THE SUN IS'),
         (ROOT/'docs/store/preview-3.png', 'BATTERY, ANIMATED')]
FD, GAP = 172*S, 36*S
fx = W - 86*S - (FD*3 + GAP*2)
fy = 268*S
for path, cap in faces:
    face = Image.open(path).convert('RGB').resize((FD,FD), Image.LANCZOS)
    mask = Image.new('L',(FD*4,FD*4),0); ImageDraw.Draw(mask).ellipse([0,0,FD*4,FD*4], fill=255)
    mask = mask.resize((FD,FD), Image.LANCZOS)
    sh = Image.new('RGBA',(FD+80*S,FD+80*S),(0,0,0,0))
    ImageDraw.Draw(sh).ellipse([40*S,40*S,FD+40*S,FD+40*S], fill=(0,0,0,155))
    sh = sh.filter(ImageFilter.GaussianBlur(17*S))
    img.paste(Image.new('RGB',(FD+80*S,FD+80*S),(0,0,0)), (fx-40*S, fy-40*S), sh.split()[3])
    img.paste(face, (fx,fy), mask)
    ring = Image.new('RGBA',(FD*4,FD*4),(0,0,0,0))
    ImageDraw.Draw(ring).ellipse([2,2,FD*4-2,FD*4-2], outline=(255,224,182,125), width=int(4.5*S))
    img.paste(Image.new('RGB',(FD,FD),(255,224,182)), (fx,fy), ring.resize((FD,FD), Image.LANCZOS).split()[3])
    d = ImageDraw.Draw(img,'RGBA')
    cw = tracked_w(d, cap, f_cap, track=1.6)
    tracked(d, (fx+(FD-cw)/2, fy+FD+26*S), cap, f_cap, (234,219,196), track=1.6)
    fx += FD + GAP

# ---------- footer ----------
devices = ['fenix 9 Pro Solar','fenix 8 Solar','fenix 7 Solar','Enduro 3','Enduro 2',
           'tactix','quatix','Forerunner 955 Dual Power']
yf, x = H - 46*S, M
for i, dev in enumerate(devices):
    d.text((x,yf), dev, font=f_foot, fill=(126,132,148))
    x += d.textlength(dev, font=f_foot)
    if i != len(devices)-1:
        d.text((x+11*S, yf), '·', font=f_foot, fill=(80,86,101)); x += 25*S

out = ROOT/'docs/hero-1440x720.png'
img.resize((1440,720), Image.LANCZOS).save(out, optimize=True, compress_level=9)
print('wrote', out)
