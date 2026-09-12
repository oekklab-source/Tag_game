"""Blender の試作フレームを確認用 GIF とコマ送り一覧にまとめる。"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent / 'preview' / 'slide'
FONT = ImageFont.truetype('C:/Windows/Fonts/meiryo.ttc', 18)
SMALL = ImageFont.truetype('C:/Windows/Fonts/meiryo.ttc', 14)


def label(mode, frame):
    if mode == 'normal':
        return '通常：座る' if frame < 7 else '通常：足を前に出して滑る'
    if frame < 10:
        return '逆走：少し登る'
    if frame <= 15:
        return '逆走：前へ倒れる'
    if frame < 46:
        return '逆走：足から滑り戻る'
    if frame <= 54:
        return '起き上がり：約0.27秒'
    return '走り姿勢へ復帰'


def card(mode, frame):
    canvas = Image.new('RGB', (560, 468), '#17212f')
    with Image.open(OUT / mode / f'{frame:03d}.png') as shot:
        canvas.paste(shot.convert('RGB'), (0, 48))
    ImageDraw.Draw(canvas).text((18, 10), label(mode, frame), font=FONT, fill='white')
    return canvas


for mode in ('normal', 'reverse'):
    frames = [card(mode, i) for i in range(60)]
    frames[0].save(OUT / f'{mode}.gif', save_all=True, append_images=frames[1:],
                   duration=[33] * 59 + [650], loop=0, optimize=False)

poses = [('normal', 0), ('normal', 7), ('normal', 25),
         ('reverse', 5), ('reverse', 13), ('reverse', 30),
         ('reverse', 46), ('reverse', 49), ('reverse', 54)]
sheet = Image.new('RGB', (1200, 1080), '#17212f')
draw = ImageDraw.Draw(sheet)
draw.text((24, 12), '滑り台モーション試作｜上から滑る / 逆走して足から滑り戻る', font=FONT, fill='white')
for i, (mode, frame) in enumerate(poses):
    tile = card(mode, frame).resize((390, 326))
    x, y = 5 + (i % 3) * 400, 52 + (i // 3) * 340
    sheet.paste(tile, (x, y))
    draw.rounded_rectangle((x + 8, y + 40, x + 36, y + 68), radius=5, fill='#17212f')
    draw.text((x + 15, y + 42), str(i + 1), font=SMALL, fill='white')
draw.text((18, 1038), '見た目の試作です。移動操作・出口判定・ネット同期はゲーム組み込み時に確認します。', font=SMALL, fill='#bdcbd9')
sheet.save(OUT / 'contact_sheet.jpg', quality=92)
print(OUT)
