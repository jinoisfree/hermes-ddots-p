#!/usr/bin/env python3
"""Draw the idle pose asleep: one eye shut, then both with the mouth falling open and drooling,
then the head nodding forward a little and a little more while the drool runs longer.
Run by hand; the build only reads the result."""
import bisect
from pathlib import Path
import math
from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
PET = ROOT / 'Resources' / 'Pet'
W, H = 192, 208
EYES = ((61.5, 54.6, 3.6), (88.3, 49.7, 3.2))   # each eye's middle and half its width; the second sits beside the phone
INK = (16, 12, 12, 255)
NODS = (0, 3, 6)           # how far the head comes down in each frame
DROOL = (0.6, 0.8, 1.0)    # how much of the drool runs below the lip in each of those frames
# The open mouth's shape, taken from a reference drawing and given in its pixels: where its eyes sit, where the line
# from its nose meets the upper lip, the middle of the mouth's outline going round from there, the top of the tongue,
# and the drool's outline from the lip down. The mouth is drawn in the pet's own line and colours.
TRACED_EYES = ((80.0, 63.5), (120.0, 72.5))
TRACED_NOSE = (92.0, 75.5)
TRACED_MOUTH = ((92.0, 75.5), (95.5, 76.5), (98.0, 78.0), (101.0, 80.2), (103.5, 82.5), (105.5, 84.8), (106.6, 87.5),
                (107.4, 91.0), (106.8, 93.4), (103.0, 94.4), (97.0, 94.3), (92.5, 93.2), (88.0, 91.9), (83.5, 90.8),
                (80.4, 89.0), (78.6, 86.2), (78.8, 83.2), (80.2, 80.4), (82.4, 77.8), (85.2, 76.2), (88.6, 75.4))
TRACED_TONGUE = ((82.0, 92.0), (84.5, 89.3), (88.0, 86.9), (92.0, 85.3), (96.5, 84.9), (100.5, 85.5), (104.0, 87.0), (108.5, 90.0))
TRACED_DROOL = ((97.6, 94.6), (99.0, 97.6), (101.0, 99.6), (101.0, 108.0), (101.4, 112.4), (102.6, 114.6), (104.0, 115.2),
                (105.4, 114.6), (106.6, 112.4), (106.8, 108.0), (106.6, 99.6), (107.4, 96.6), (107.2, 94.4))
MOUTH_UNDER_NOSE = (78.2, 58.4)   # where that same point goes on the pet, just under its nose
MIRRORED = True   # drawn the other way round from the reference: hanging open and drooling on the pet's left
HEAD_ENDS, BODY_BEGINS = 80, 112   # everything above moves whole; the body below stays put


def ease(v):
    v = min(1.0, max(0.0, v))
    return v*v*(3 - 2*v)


def nod(im, drop):
    """Lower the head, the phone and the paws holding it; the chest under them takes up the difference.
    The pillow on either side of the head stays where it is."""
    if drop == 0:
        return im
    px = im.load()
    out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    po = out.load()
    for x in range(W):
        across = ease((x - 20)/12)*(1 - ease((x - 124)/10))
        lands = [y + drop*across*(1 - ease((y - HEAD_ENDS)/(BODY_BEGINS - HEAD_ENDS))) for y in range(H + 1)]
        column = [tuple(c*p[3]/255 for c in p[:3]) + (p[3],) for p in (px[x, y] for y in range(H))]
        for y in range(H):
            acc = [0.0]*4
            for part in range(4):  # four samples to the pixel
                t = y + (part + 0.5)/4
                k = bisect.bisect_right(lands, t) - 1
                if k < 0 or k >= H:
                    continue
                sy = k + (t - lands[k])/(lands[k + 1] - lands[k]) - 0.5
                a0 = min(H - 1, max(0, int(sy // 1)))
                a1 = min(H - 1, a0 + 1)
                w = min(1.0, max(0.0, sy - a0))
                for c in range(4):
                    acc[c] += (column[a0][c]*(1 - w) + column[a1][c]*w)/4
            r, g, b, a = acc
            po[x, y] = (round(r*255/a), round(g*255/a), round(b*255/a), round(a)) if a >= 1 else (0, 0, 0, 0)
    return out


def shut(im, eyes):
    """Paint an open eye out and draw it shut: a nearly flat line sagging a little in the middle, the way a sleeping eye is drawn."""
    k = 8
    fur = im.getpixel((75, 50))
    tilt = math.atan2(EYES[1][1] - EYES[0][1], EYES[1][0] - EYES[0][0])
    over = Image.new('RGBA', (W*k, H*k), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    for x, y, half in eyes:
        d.ellipse([(x - 4.6)*k, (y - 4.6)*k, (x + 4.6)*k, (y + 4.6)*k], fill=fur)
        points = []
        for i in range(17):
            t = -1 + i/8
            along, down = t*half, 0.8*(1 - t*t) - 0.2
            points.append(((x + along*math.cos(tilt) - down*math.sin(tilt))*k, (y + along*math.sin(tilt) + down*math.cos(tilt))*k))
        d.line(points, fill=INK, width=round(2.3*k), joint='curve')
        for px, py in (points[0], points[-1]):
            d.ellipse([px - 1.15*k, py - 1.15*k, px + 1.15*k, py + 1.15*k], fill=INK)
    out = im.copy()
    out.alpha_composite(over.convert('RGBa').resize((W, H), Image.BOX).convert('RGBA'))
    return out


def smooth(points, closed, n=8):
    """A curve through every point (Catmull-Rom), n steps between each pair."""
    pts = list(points)
    count = len(pts) if closed else len(pts) - 1
    out = []
    for i in range(count):
        p0 = pts[(i - 1) % len(pts)] if closed or i > 0 else pts[0]
        p1, p2 = pts[i], pts[(i + 1) % len(pts)]
        p3 = pts[(i + 2) % len(pts)] if closed or i + 2 < len(pts) else pts[-1]
        for j in range(n):
            t = j/n
            out.append(tuple(0.5*(2*p1[c] + (-p0[c] + p2[c])*t + (2*p0[c] - 5*p1[c] + 4*p2[c] - p3[c])*t*t
                                  + (-p0[c] + 3*p1[c] - 3*p2[c] + p3[c])*t*t*t) for c in range(2)))
    if not closed:
        out.append(pts[-1])
    return out


def snore(im, drool):
    """Paint the closed mouth out and draw it hanging open, the reference drawing's shape in the pet's own line:
    sized to the eyes and turned with the face, a tongue in the bottom, and drool that still hangs straight down."""
    k = 8
    fur = im.getpixel((75, 50))
    tilt = math.atan2(EYES[1][1] - EYES[0][1], EYES[1][0] - EYES[0][0])
    flip = -1 if MIRRORED else 1
    scale = math.dist(EYES[0][:2], EYES[1][:2])/math.dist(*TRACED_EYES)
    turn = tilt - math.atan2(flip*(TRACED_EYES[1][1] - TRACED_EYES[0][1]), TRACED_EYES[1][0] - TRACED_EYES[0][0])

    def face(p):
        dx, dy = flip*(p[0] - TRACED_NOSE[0]), p[1] - TRACED_NOSE[1]
        return (MOUTH_UNDER_NOSE[0] + scale*(dx*math.cos(turn) - dy*math.sin(turn)),
                MOUTH_UNDER_NOSE[1] + scale*(dx*math.sin(turn) + dy*math.cos(turn)))

    def fine(points):
        return [(x*k, y*k) for x, y in points]

    out = im.copy()
    px = out.load()
    # The closed mouth on either side of the nose; the nose and the line under it stay.
    for y in range(57, 64):
        for x in range(66, 91):
            if not (75 <= x <= 81 and y <= 58):
                px[x, y] = fur
    mouth = fine(smooth([face(p) for p in TRACED_MOUTH], closed=True))
    tongue_top = fine(smooth([face(p) for p in TRACED_TONGUE], closed=False))
    over = Image.new('RGBA', (W*k, H*k), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    d.polygon(mouth, fill=(176, 58, 62, 255))
    # The tongue: everything inside the mouth below the line across its top.
    inside = Image.new('L', over.size, 0)
    ImageDraw.Draw(inside).polygon(mouth, fill=255)
    below = Image.new('L', over.size, 0)
    ImageDraw.Draw(below).polygon(tongue_top + [(tongue_top[-1][0], H*k), (tongue_top[0][0], H*k)], fill=255)
    pink = Image.new('RGBA', over.size, (238, 134, 136, 255))
    over.paste(pink, (0, 0), ImageChops.multiply(inside, below))
    d.line(mouth + mouth[:2], fill=INK, width=round(2.2*k), joint='curve')
    # The drool leaves the lower lip where the turned mouth puts it, then hangs straight down, longer as the head drops.
    lip = face(TRACED_DROOL[0])
    top = TRACED_DROOL[0]
    run = [(lip[0] + flip*scale*(x - top[0]), lip[1] + scale*drool*(y - top[1])) for x, y in TRACED_DROOL]
    run = fine(smooth(run, closed=True))
    d.polygon(run, fill=(186, 224, 246, 255))
    d.line(run + run[:2], fill=(64, 128, 182, 255), width=round(1.2*k), joint='curve')
    sx = [x for x, _ in run]
    ys = [y for _, y in run]
    mid = (min(sx) + max(sx))/2 - 0.5*k
    d.line([(mid, min(ys) + 3.0*k), (mid, max(ys) - 2.0*k)], fill=(255, 255, 255, 255), width=round(0.7*k))
    out.alpha_composite(over.convert('RGBa').resize((W, H), Image.BOX).convert('RGBA'))
    return out


def draw():
    atlas = Image.open(PET / 'spritesheet.webp').convert('RGBA')
    idle = atlas.crop((0, 0, W, H))
    asleep = shut(idle, EYES)
    frames = [shut(idle, EYES[:1])] + [nod(snore(asleep, drool), drop) for drop, drool in zip(NODS, DROOL)]
    sheet = Image.new('RGBA', (W*len(frames), H), (0, 0, 0, 0))
    for column, frame in enumerate(frames):
        sheet.paste(frame, (column*W, 0))
    sheet.save(PET / 'doze.png')
    print('잠든 얼굴을 그렸습니다:', PET / 'doze.png')


if __name__ == '__main__':
    draw()
