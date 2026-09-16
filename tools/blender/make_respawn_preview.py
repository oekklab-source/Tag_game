"""描画済みのリスポーン試作を等速GIFとコマ送り一覧にする。"""
from pathlib import Path
import json
import struct
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent / 'preview' / 'respawn'
font = ImageFont.truetype('C:/Windows/Fonts/meiryo.ttc', 19)
small = ImageFont.truetype('C:/Windows/Fonts/meiryo.ttc', 15)


def card(frame):
    canvas = Image.new('RGB', (640, 564), '#17212f')
    with Image.open(OUT / f'{frame:03d}.png') as shot:
        canvas.paste(shot.convert('RGB'), (0, 44))
    label = '座って目が回る' if frame < 81 else ('短く立ち上がる' if frame < 90 else '3秒で復帰')
    ImageDraw.Draw(canvas).text((18, 9), f'{frame / 30:.1f}秒 / 3.0秒　{label}', font=font, fill='white')
    return canvas


frames = [card(i) for i in range(91)]
# GIFの時間単位は10ms。30/30/40msの3枚で100msを作り、3秒を維持する。
frames[0].save(OUT / 'respawn_dizzy.gif', save_all=True, append_images=frames[1:],
               duration=[30, 30, 40] * 30 + [600], loop=0, optimize=False)
sheet = Image.new('RGB', (1200, 1120), '#17212f')
draw = ImageDraw.Draw(sheet)
draw.text((18, 10), 'リスポーン後の目回り｜座って円を描く揺れ → 3秒以内に立ち上がる', font=font, fill='white')
for i, frame in enumerate([0, 7, 14, 21, 54, 81, 84, 87, 90]):
    x, y = (i % 3) * 400 + 5, (i // 3) * 354 + 48
    sheet.paste(frames[frame].resize((390, 344)), (x, y))
    draw.rounded_rectangle((x + 8, y + 35, x + 34, y + 62), radius=4, fill='#17212f')
    draw.text((x + 14, y + 36), str(i + 1), font=small, fill='white')
sheet.save(OUT / 'contact_sheet.jpg', quality=92)
data = (OUT / 'respawn_dizzy.glb').read_bytes()
size = struct.unpack_from('<I', data, 12)[0]
gltf = json.loads(data[20:20 + size])
clip = next(a for a in gltf['animations'] if a['name'] == 'RespawnDizzy')
duration = max(gltf['accessors'][s['input']]['max'][0] for s in clip['samplers'])
assert abs(duration - 3.0) < 0.001, duration
print('RespawnDizzy: verified 3.0 seconds; GIF and contact sheet ready')
