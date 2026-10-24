#!/usr/bin/env python3
"""Extract lossless build assets; never alter the upstream WebP or manifest."""
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PET = ROOT / 'Resources' / 'Pet'
OUTPUT = ROOT / '.build' / 'assets'
EXPECTED = '316b98b0445cdf0ac50dda91128e5772366f49787a4634addbfb1409c99dca35'
# The idle pose with its right paw lifted, drawn by draw_wave.py, pinned by its pixels so that only an intended redraw changes it.
WAVE = '69aaf32cb6f7a0840c562f1aebac7d47e90bc10cd6ef63f654656c18158b0d73'
# The idle pose asleep and nodding, drawn by draw_doze.py and pinned the same way.
DOZE = '966271ce8e97c979b5f14fa49616e0edb498ebf3580504a61791a51893de61a1'
# Eight authored frames per state, with neighboring-cell fragments clipped before normalization.
WORK_MOTIONS = {
    # The idle pose with a sulky face, shaking its phone, drawn by draw_approval_phone.py.
    'approval-phone.png': 'e44747393e6313fd91fd40aa50ea5465a1ff1b3eb01492cc957be105356bcb57',
}

def prepare():
    source = PET / 'spritesheet.webp'
    assert hashlib.sha256(source.read_bytes()).hexdigest() == EXPECTED, 'Upstream asset hash changed'
    assert json.loads((PET / 'pet.json').read_text())['spriteVersionNumber'] == 2
    wave = Image.open(PET / 'wave.png').convert('RGBA')
    assert wave.size == (768, 208) and hashlib.sha256(wave.tobytes()).hexdigest() == WAVE, 'Wave art changed'
    doze = Image.open(PET / 'doze.png').convert('RGBA')
    assert doze.size == (768, 208) and hashlib.sha256(doze.tobytes()).hexdigest() == DOZE, 'Doze art changed'
    for filename, checksum in WORK_MOTIONS.items():
        motion = Image.open(PET / filename).convert('RGBA')
        assert motion.size == (1536, 208), f'{filename}: expected eight 192×208 frames'
        assert hashlib.sha256(motion.tobytes()).hexdigest() == checksum, f'{filename}: art changed'
    atlas = Image.open(source).convert('RGBA')
    assert atlas.size == (1536, 2288)
    # The wave is the idle pose itself: its first frame is the idle frame, and the others change only the raised arm's side above the knee.
    idle = atlas.crop((0, 0, 192, 208))
    assert wave.crop((0, 0, 192, 208)).tobytes() == idle.tobytes(), 'Wave starts from the idle pose'
    for column in range(1, 4):
        assert wave.crop((column*192, 111, column*192 + 192, 208)).tobytes() == idle.crop((0, 111, 192, 208)).tobytes(), 'Wave keeps the idle body'
    # So is the phone shake: below the arms it is always the idle body.
    approval = Image.open(PET / 'approval-phone.png').convert('RGBA')
    for column in range(8):
        assert approval.crop((column*192, 110, column*192 + 192, 208)).tobytes() == idle.crop((0, 110, 192, 208)).tobytes(), 'Phone shake keeps the idle body'
    OUTPUT.mkdir(parents=True, exist_ok=True)
    atlas.save(OUTPUT / 'spritesheet.png')
    assert Image.open(OUTPUT / 'spritesheet.png').tobytes() == atlas.tobytes()
    iconset = OUTPUT / 'ddots.iconset'
    iconset.mkdir(exist_ok=True)
    cat = atlas.crop((0, 0, 192, 208))
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            width = size * scale
            canvas = Image.new('RGBA', (width, width))
            frame = cat.resize((round(width * 192 / 208), width), Image.Resampling.LANCZOS)
            canvas.alpha_composite(frame, ((width - frame.width) // 2, 0))
            canvas.save(iconset / f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png')
    canvas.save(OUTPUT / 'ddots.icns', format='ICNS')
    print('태식이 원본 체크섬·PNG 픽셀 일치: 통과')

if __name__ == '__main__':
    prepare()
