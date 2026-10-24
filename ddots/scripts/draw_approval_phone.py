#!/usr/bin/env python3
"""Draw the approval wait on the idle pose: the same cat and size, with the sulky face of the earlier drawing, the
other paw resting on the belly, and the phone shaken in the right paw beside the face. Run by hand; the build only
reads the PNG."""
import io
import math
import subprocess
from collections import deque
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
PET = ROOT / 'Resources' / 'Pet'
W, H, S = 192, 208, 4  # cell size; lines are drawn at four times the size, then reduced
INK = (16, 12, 12, 255)
# The earlier approval drawing, whose sulky eyes and mouth this one keeps.
SULKY_SOURCE = '87cd5e7361626d34c533e15c3756e3d246edaa9b'

# What the phone and the paw holding it hid on the idle pose, and what is redrawn there.
UNCOVERED = [(93, 43), (100, 40), (111, 40), (121, 43), (127, 55), (136, 62), (138, 72), (137, 88), (126, 92),
             (116, 86), (116, 82), (100, 82), (97, 70), (93, 62)]
PATCH = [(93, 43), (100, 40), (111, 40), (113.5, 47.5), (104, 46.5), (96, 45.5)]
# The head's outline carrying on behind the phone and down the body's side; the pillow is to its right.
OUTLINE = [(108, 38), (112, 44), (115, 50), (117, 56), (121, 62), (125, 70), (128, 79), (129.5, 87), (129, 93)]
PATCH_EDGE = [(92, 44), (100, 45.3), (108, 46.3), (113.5, 47)]
# The other arm reached up to the phone; it is cleared and drawn short, its paw on the belly.
LONG_ARM = [(59, 88), (91, 55), (111, 57), (111, 85), (80, 109), (69, 107)]
SHORT_ARM = [(68.5, 84), (75, 80.5), (84, 77.5), (89, 78), (92.5, 81.5), (92.5, 86.5), (89, 90.5), (83, 94), (79, 97.5),
             (74, 102.5)]
# The idle face's eyes and mouth, and the earlier drawing's sulky ones: (box there, centre here).
IDLE_FACE = [(58, 50, 70, 59), (86, 45, 96, 54), (70, 50, 90, 62)]
SULKY = [((84, 92, 100, 101), (64, 54.5)), ((106, 92, 122, 100), (88, 49.5)), ((98, 96, 110, 105), (79.5, 58))]
SULKY_SCALE, FACE_TILT = 1.2, -10.5  # the earlier drawing is level and a little smaller

# The phone, whole, where the idle one is, and the idle paw that holds it.
PHONE = [(95, 42.5), (120.5, 42.5), (124.5, 80.5), (100.5, 80.5)]
CAMERA = (101, 49)
PAW = [(116, 55), (126, 56), (132, 59), (135, 66), (135, 84), (124, 89), (115, 83), (113, 70)]
WRIST = (128, 84)
# Per frame: clockwise degrees about the wrist, sideways travel, and whether shake marks show. Small toward the face so
# the eye stays clear, large away from it.
MOTION = [(0, 0, False), (-4, -1, False), (14, 3, True), (-3, -1, False), (12, 3, True), (-4, -1, False),
          (14, 3, True), (0, 0, False)]
MARKS = [(136, 32), (141, 41)]


def big():
    return Image.new('RGBA', (W*S, H*S), (0, 0, 0, 0))


def up(points):
    return [(x*S, y*S) for x, y in points]


def reduced(layer):
    return layer.resize((W, H), Image.Resampling.LANCZOS)


def polygon(points):
    mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def kind(p):
    """fur, pillow or patch for a flat colour; None for outlines and the blends at their edges."""
    r, g, b, a = p
    if a < 250:
        return None
    if min(r, g, b) > 246:
        return 'fur'
    if b > r + 30 and b > 200:
        return 'pillow'
    if r >= 35 and r > b + 20 and r > g + 8:
        return 'patch'
    return None


def fill(image, region, wanted):
    """Fill the region outward from the nearest untouched pixels of the wanted kind, so it keeps their tone."""
    pixels, inside = image.load(), region.load()
    queue, done = deque(), set()

    def spread(x, y):
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < W and 0 <= ny < H and inside[nx, ny] and (nx, ny) not in done:
                done.add((nx, ny))
                pixels[nx, ny] = pixels[x, y]
                queue.append((nx, ny))

    for y in range(H):
        for x in range(W):
            if not inside[x, y] and kind(pixels[x, y]) == wanted:
                spread(x, y)
    while queue:
        spread(*queue.popleft())


def lines(image, *strokes):
    layer = big()
    draw = ImageDraw.Draw(layer)
    for points, width in strokes:
        draw.line(up(points), fill=INK, width=round(width*S), joint='curve')
    image.alpha_composite(reduced(layer))


def sulky_face(image):
    data = subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{SULKY_SOURCE}:Resources/Pet/approval-phone.png'])
    earlier = Image.open(io.BytesIO(data)).convert('RGBA')
    for box, (cx, cy) in SULKY:
        crop = earlier.crop(box)
        ink = Image.new('L', crop.size, 0)
        for y in range(crop.height):
            for x in range(crop.width):
                r, g, b, a = crop.getpixel((x, y))
                ink.putpixel((x, y), max(0, min(255, (235 - min(r, g, b))*255//180))*a//255)
        ink = ink.resize((round(ink.width*SULKY_SCALE*S), round(ink.height*SULKY_SCALE*S)), Image.Resampling.BICUBIC)
        ink = ink.rotate(-FACE_TILT, expand=True, resample=Image.Resampling.BICUBIC)
        ink = ink.resize((round(ink.width/S), round(ink.height/S)), Image.Resampling.LANCZOS)
        stroke = Image.new('RGBA', ink.size, INK)
        stroke.putalpha(ink)
        image.alpha_composite(stroke, (round(cx - ink.width/2), round(cy - ink.height/2)))


def body(idle):
    """The idle pose without its phone, paw and long arm, with the sulky face."""
    image = idle.copy()
    uncovered = polygon(UNCOVERED)
    patch = ImageChops.multiply(uncovered, polygon(PATCH))
    pillow = ImageChops.multiply(uncovered, polygon(OUTLINE + [(140, 93), (140, 38)]))
    fur = ImageChops.subtract(ImageChops.subtract(uncovered, patch), pillow)
    for box in IDLE_FACE:
        ImageDraw.Draw(fur).rectangle(box, fill=255)
    fur = ImageChops.lighter(fur, polygon(LONG_ARM))
    for region, wanted in ((patch, 'patch'), (pillow, 'pillow'), (fur, 'fur')):
        fill(image, region, wanted)
    lines(image, (PATCH_EDGE, 2.6), (OUTLINE, 2.8), (SHORT_ARM, 2.8))
    sulky_face(image)
    return image


def phone(idle):
    """A whole phone where the idle one is, with the idle paw, fur and outline only, in front of it."""
    layer = big()
    shape = Image.new('L', layer.size, 0)
    ImageDraw.Draw(shape).polygon(up(PHONE), fill=255)
    shape = shape.filter(ImageFilter.GaussianBlur(2.5*S)).point(lambda v: 255 if v >= 128 else 0)
    inner = shape.filter(ImageFilter.MinFilter(2*round(2.6*S) + 1))
    layer.paste(Image.new('RGBA', layer.size, INK), mask=shape)
    layer.paste(Image.new('RGBA', layer.size, idle.getpixel((110, 60))), mask=inner)
    draw = ImageDraw.Draw(layer)
    cx, cy = CAMERA
    draw.ellipse(up([(cx - 2, cy - 2), (cx + 2, cy + 2)]), fill=INK)
    draw.ellipse(up([(cx - 1, cy - 1), (cx + 1, cy + 1)]), fill=(205, 205, 195, 255))
    held = reduced(layer)
    paw = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    inside = polygon(PAW).load()
    for y in range(H):
        for x in range(W):
            if inside[x, y] and kind(idle.getpixel((x, y))) not in ('pillow', 'patch') and idle.getpixel((x, y))[3] >= 60:
                paw.putpixel((x, y), idle.getpixel((x, y)))
    held.alpha_composite(paw)
    return held


def shaken(held, angle, travel):
    t = math.radians(angle)
    c, s = math.cos(t), math.sin(t)
    x0, y0 = WRIST
    x1 = x0 + travel
    inverse = (c, s, x0 - c*x1 - s*y0, -s, c, y0 + s*x1 - c*y0)
    return held.convert('RGBa').transform((W, H), Image.Transform.AFFINE, inverse,
                                        Image.Resampling.BICUBIC).convert('RGBA')


def marks():
    layer = big()
    draw = ImageDraw.Draw(layer)
    for x, y in MARKS:
        draw.arc(up([(x - 7, y - 7), (x + 7, y + 7)]), -70, 20, fill=INK, width=round(2.6*S))
    return reduced(layer)


def draw():
    idle = Image.open(PET / 'spritesheet.webp').convert('RGBA').crop((0, 0, W, H))
    still, held = body(idle), phone(idle)
    sheet = Image.new('RGBA', (W*len(MOTION), H))
    for column, (angle, travel, shake) in enumerate(MOTION):
        frame = still.copy()
        frame.alpha_composite(shaken(held, angle, travel))
        if shake:
            frame.alpha_composite(marks())
        sheet.paste(frame, (column*W, 0))
    sheet.save(PET / 'approval-phone.png')
    print('기본 자세에서 휴대폰을 흔드는 그림을 다시 그렸습니다:', PET / 'approval-phone.png')


if __name__ == '__main__':
    draw()
