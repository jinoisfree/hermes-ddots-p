#!/usr/bin/env python3
"""Draw the wave on the idle pose: the sheet's own raised paw, its forearm shortened, set on the idle cat's body so the
body and size stay those of the idle pose. Run by hand; the build only reads the result."""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
PET = ROOT / 'Resources' / 'Pet'
W, H = 192, 208
# The raised arm in the second and third frames: where it leaves the body, the paw's tip, and its left edge.
ARMS = {1: ((128.5, 81), (140.5, 28.5), [(118.8, 81), (118.8, 60), (124.0, 45.5), (121.6, 39.5)]),
        2: ((127.5, 82), (139.5, 27.5), [(118.8, 82), (118.8, 60), (123.4, 45.5), (121.0, 39.5)])}
WRIST, CUT = 33, 23
# The top of the paw that holds the phone in the sheet's frame with the arm down; the pillow above it is uncovered there.
REST_PAW = 63
# The raised arm is moved onto the idle pose by this much: the idle cat sits a little higher and to the left in its cell.
SHIFT = (-2, -3)
# Of the sheet's frame, the arm and the body beside it down to SEAM (in the idle pose's rows) replace the idle drawing,
# right of the phone (PHONE) and below the pillow's top (TOP). Below SEAM both bodies share one outline.
PHONE, TOP, SEAM = 118, 47, 110


def sample(im, x, y):
    """Bilinear, on colour weighted by alpha, so edges against nothing stay clean."""
    x0, y0 = math.floor(x), math.floor(y)
    acc = [0.0]*4
    for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
        xx, yy = x0 + dx, y0 + dy
        if not (0 <= xx < W and 0 <= yy < H):
            continue
        w = (1 - abs(x - xx))*(1 - abs(y - yy))
        r, g, b, a = im.getpixel((xx, yy))
        acc[0] += r*a*w; acc[1] += g*a*w; acc[2] += b*a*w; acc[3] += a*w
    if acc[3] < 1:
        return (0, 0, 0, 0)
    return (round(acc[0]/acc[3]), round(acc[1]/acc[3]), round(acc[2]/acc[3]), round(acc[3]))


def shorter_arm(im, base, tip, left, pillow, rest):
    """Take CUT px out of the forearm, between the body and the wrist; the paw itself moves down whole.
    Above the lowered paw of `rest` (the frame with the arm down) the pillow and its outline are taken from that frame."""
    length = math.hypot(tip[0] - base[0], tip[1] - base[1])
    u = ((tip[0] - base[0])/length, (tip[1] - base[1])/length)
    n = (-u[1], u[0])
    keep = (WRIST - CUT)/WRIST
    arm = Image.new('L', (W, H), 0)
    ImageDraw.Draw(arm).polygon(left + [(tip[0] - 18.5, tip[1] - 6), (tip[0] - 6, tip[1] - 12), (tip[0] + 8, tip[1] - 12),
                                        (tip[0] + 18, tip[1] - 2), (tip[0] + 16, tip[1] + 14), (base[0] + 21, base[1] + 6),
                                        (base[0] - 12, base[1] + 4)], fill=255)
    behind = Image.new('L', (W, H), 0)  # where the pillow lies behind the arm
    ImageDraw.Draw(behind).polygon([(100, 44.5), (128, 44.5), (132.5, 50), (134.5, 60), (136.5, 70), (138.5, 82),
                                    (144, 100), (110, 100)], fill=255)
    out = im.copy()

    def along(x, y):
        return (x - base[0])*u[0] + (y - base[1])*u[1]

    for y in range(H):
        for x in range(W):
            if arm.getpixel((x, y)) and along(x + 0.5, y + 0.5) >= 0:
                out.putpixel((x, y), rest.getpixel((x, y)) if y < REST_PAW else pillow if behind.getpixel((x, y)) else (0, 0, 0, 0))
    for y in range(H):
        for x in range(W):
            t2 = along(x + 0.5, y + 0.5)
            if not arm.getpixel((x, y)) or t2 < 0:
                continue
            side = (x + 0.5 - base[0])*n[0] + (y + 0.5 - base[1])*n[1]
            t = t2/keep if t2 < keep*WRIST else WRIST + (t2 - keep*WRIST)
            sx, sy = base[0] + t*u[0] + side*n[0] - 0.5, base[1] + t*u[1] + side*n[1] - 0.5
            if not (0 <= sx < W - 1 and 0 <= sy < H - 1) or not arm.getpixel((round(sx), round(sy))):
                continue
            nearest = im.getpixel((round(sx), round(sy)))
            if nearest[3] <= 40 or nearest[2] > nearest[0] + 18:  # nothing there, or pillow
                continue
            p = sample(im, sx, sy)
            under = out.getpixel((x, y))
            a = p[3]/255
            out.putpixel((x, y), tuple(round(p[i]*a + under[i]*(1 - a)) for i in range(3)) + (max(p[3], under[3]),))
    return out


def is_cat(p):
    r, g, b, a = p
    if a < 128 or b - r > 18:  # nothing there, or pillow
        return False
    return min(r, g, b) > 200 or (30 <= r <= 110 and r - b > 15)  # fur, or the brown patch


def on_idle(idle, frame):
    """Lay the sheet frame's arm, with its outline and the body beside it, over the idle pose."""
    patch = Image.new('L', (W, H), 0)
    for y in range(TOP, SEAM - SHIFT[1] + 1):
        for x in range(PHONE + 1, W):
            if is_cat(frame.getpixel((x, y))):
                patch.putpixel((x, y), 255)
    patch = patch.filter(ImageFilter.MaxFilter(7))  # take in the outline around the fur
    ImageDraw.Draw(patch).rectangle([0, 0, PHONE - 1, H], fill=0)
    ImageDraw.Draw(patch).rectangle([0, SEAM - SHIFT[1] + 1, W, H], fill=0)
    moved = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    moved.paste(frame, SHIFT)
    mask = Image.new('L', (W, H), 0)
    mask.paste(patch, SHIFT)
    out = idle.copy()
    out.alpha_composite(Image.composite(moved, Image.new('RGBA', (W, H), (0, 0, 0, 0)), mask))
    return out


def draw():
    atlas = Image.open(PET / 'spritesheet.webp').convert('RGBA')
    frames = [atlas.crop((c*W, 3*H, c*W + W, 4*H)) for c in range(4)]
    pillow = frames[0].getpixel((122, 52))
    sheet = Image.new('RGBA', (W*4, H), (0, 0, 0, 0))
    idle = atlas.crop((0, 0, W, H))
    # It rests, then waves: up, over, and up again.
    for column, raised in enumerate([None, 1, 2, 1]):
        frame = idle
        if raised:
            base, tip, left = ARMS[raised]
            frame = on_idle(idle, shorter_arm(frames[raised], base, tip, left, pillow, frames[0]))
        sheet.paste(frame, (column*W, 0))
    sheet.save(PET / 'wave.png')
    print('손 흔들기 그림을 다시 그렸습니다:', PET / 'wave.png')


if __name__ == '__main__':
    draw()
