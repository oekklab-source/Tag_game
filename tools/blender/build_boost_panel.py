"""ダッシュパネル（レースゲームでおなじみの、山型の矢印が流れるダッシュ板）を一から組み立てて glTF に書き出す。

    blender -b -P tools/blender/build_boost_panel.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/boost_panel.blend      編集元（.gdignore で Godot のインポート対象外）
    tools/blender/boost_panel_tile.png   板の絵（タイル1枚）。glb に埋め込まれる
    assets/gimmicks/boost_panel.glb      Godot が読むモデル

**8m 角の正方形。** ベルトコンベアだった頃は搬送方向に逆らうと通り抜けられなかったが、
今は踏んだ人自身の進行方向へ蹴り出すので四方から乗れる（boost_panel.gd を参照）。
5m x 10m の長方形だと「長い方が正面」に見えて仕様と食い違うので、
正方形にして四方を等価にしてある。

**山型は一方向（本家どおり）にした。** 以前は「片方向の矢印にすると逆から乗った人が
矢印と逆へ加速することになり、見た目が仕様に嘘をつく」として四方ぶん置いていたが、
2026-10-04 に本家の見た目を優先する判断で意図的に外した。
挙動は変えていない: 蹴り出す向きは今も踏んだ人の進行方向で、
山型は向きの指示ではなく「加速する板」の記号として扱う。

構成（root は Empty の DashPad、全部その子）:
    Frame   銀色の細い枠 + 四隅のボルト
    Plate   平らな四角1枚。ピンク→橙→黄のグラデーション地（結晶モザイク）+ 白い山型の
            テクスチャを貼る。山型は Blender の +Y（= Godot の -Z = パネルの前）を向く
    Spark0..2 踏んだ瞬間に噴く火花（金・ピンク・白）

**絵はテクスチャ、流すのは Godot。** 山型の流れは Plate の UV を Godot のシェーダ
（boost_panel.gdshader）がずらして作る。Blender 側で段ごとの部品に分けて光らせる
作りだと、見た目が部品の数で決まってしまい、本家のような「1枚の板を山型が流れる」絵にならない。
タイルは縦に継ぎ目なく並ぶように作ってあるので、ずらし続けても切れ目が出ない。

全高は 0.12m に抑える。乗り越える段差ではなく床の意匠として扱わせるため、
ここを上げると「全方向から入れる」が壊れる（tests/boost_panel.gd が 0.2m で見張っている）。
Spark0..2（火花）だけは踏んだ瞬間に噴く飾りなので、この制限の外に置く。
"""

import math
import os
import sys

import bmesh
import bpy
import mathutils
import numpy as np

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "boost_panel.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "boost_panel.glb")
# tools/blender/ は .gdignore で Godot のインポート対象外。絵はここへ置いて glTF エクスポータに
# GLB へ埋め込ませるので、assets/ に PNG は増えない
TILE_PATH = os.path.join(PROJECT, "tools", "blender", "boost_panel_tile.png")

# ---- 寸法（当たり判定 BoxShape3D(8, 1.6, 8) に合わせる。Blender は Z-up・単位 m・地面 z=0）----
SIDE = 8.0
HALF = SIDE / 2                  # 4.00
CORNER_R = 0.30                  # 枠の外側の角の丸み
CORE_SQ = HALF - CORNER_R        # 芯の正方形の半辺 3.70。膨らませる前の骨格
CORNER_SEG = 6                   # 角1つあたりの分割数

FRAME_BAND = 0.20                # 枠の幅。外半辺 4.00 / 内半辺 3.80
FRAME_TOP = 0.10                 # 枠の天面。最下面は z=0（床から浮かせない）
BOLT_R = 0.07                    # 四隅のボルト。枠の幅 0.20 の中に収まる太さ
BOLT_TOP = 0.12                  # 全高。段差にならない高さに留めること
BOLT_SEG = 12

PLATE_HALF = 3.84                # 板の半辺。枠の内半辺 3.80 より 0.04 大きく、枠の下へ潜らせて隙間を作らない
PLATE_Z = 0.06                   # 板の高さ（枠の天面 0.10 より低い＝枠が縁取りに見える）
V_TILES = 2                      # 板の縦に並ぶタイル枚数。boost_panel.gdshader の tiles と揃えること

# ---- 板の絵（タイル1枚 = 板の幅いっぱい 7.68m x 縦の1周期 3.84m）----
TEX_W, TEX_H = 1024, 512         # 幅 x 高さ。1px = 0.0075m（縦横同じ）
TILE_W = PLATE_HALF * 2          # 7.68m
TILE_H = TILE_W / V_TILES        # 3.84m
CELLS_X, CELLS_Y = 20, 10        # 結晶モザイクの格子。1セル = 0.384m 角
CHEV_COLUMNS = [                 # (中心 X, 頂点 Y)。両脇と中央は半周期ずらして互い違いに流す
    (TILE_W / 6, 0.30 * TILE_H),
    (TILE_W / 2, 0.80 * TILE_H),
    (TILE_W * 5 / 6, 0.30 * TILE_H),
]
CHEV_HALF_W = 0.95               # 山型の半幅
CHEV_SLOPE = 0.85                # 腕の傾き（頂点から横へ 1m 行くと 0.85m 下がる）
CHEV_THICK = 0.62                # 帯の縦の太さ
EDGE_AA = 1.5 * (TILE_W / TEX_W)  # 縁のにじみ幅（1.5px ぶん）

SPARK_COUNT = 24
SPARK_SIZE = (0.18, 0.18, 0.022)
SPARK_RING = 3.0                 # 火花を散らす半径の上限


def srgb(r, g, b):
    """画面で見える色（sRGB）を、glTF が要求する**リニア**値へ直す。

    **ここを通さないと色が1段明るく淡くなって出る。** glTF の baseColorFactor は
    リニアなので、Godot は読み込んだ値を sRGB へ encode して albedo_color にする。
    world_data.gd の ZONE_COLORS（Godot の Color = sRGB）と同じ数字を
    そのまま書くと、ビビッドオレンジのつもりが薄い山吹になる。
    （板のテクスチャは画像なので逆に srgb() を通さない。make_plate_texture を参照）
    """
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                 for c in (r, g, b))


# ---- 配色（**すべて sRGB で書く**。world_data.gd の ZONE_COLORS と直接見比べられる） ----
# 枠は銀色。金属らしさは控えめにして、環境光の少ない場所でも暗く沈ませない
FRAME_COLOR = srgb(0.80, 0.82, 0.86)
FRAME_EMISSION = 0.05
# 地のグラデーション（テクスチャ側の色。画像は sRGB のまま書くので srgb() を通さない）
GRAD_PINK = (1.00, 0.36, 0.72)
GRAD_ORANGE = (1.00, 0.58, 0.24)
GRAD_YELLOW = (1.00, 0.88, 0.32)
# 火花は3色。1メッシュに1マテリアルしか持たせない流儀なので、色ごとにメッシュを分ける。
# 地（ピンク〜黄）の上で埋もれないよう、地と同系の色を避けて金・ピンク・白にしてある
SPARK_COLORS = [
    srgb(1.00, 0.86, 0.30),  # 金
    srgb(1.00, 0.40, 0.78),  # ピンク
    srgb(1.00, 1.00, 1.00),  # 白
]
# 火花は Godot 側で beacon.gdshader（加算合成）に差し替わる。
# ここの値は Blender プレビューと、シェーダを当て損ねた時の保険にしか効かない
GLOW_EMISSION = 1.0


# =====================================================================
# 汎用ヘルパ
# =====================================================================

def make_mat(name, rgb, emission, metallic=0.0, roughness=0.4):
    """マテリアルを作成または取得して設定する。"""
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = emission
    mat.diffuse_color = (*rgb, 1.0)
    return mat


def paint(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    return obj


def finish(bm, name):
    """bmesh をオブジェクトに落として重複頂点と法線を整える。"""
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate(verbose=False)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def arc(center, r, a0, a1, seg, ends=False):
    """center を中心に a0 から a1 へ回る円弧。既定では**両端を含めない**。

    帯の先端キャップに使うときは両端が側辺と一致するので含めない。
    角丸正方形のように弧だけで輪郭を閉じるときは ends=True で含める。
    """
    lo, hi = (0, seg + 1) if ends else (1, seg)
    return [(center[0] + math.cos(a0 + (a1 - a0) * i / seg) * r,
             center[1] + math.sin(a0 + (a1 - a0) * i / seg) * r)
            for i in range(lo, hi)]


def square_loop(core, r):
    """半辺 core の正方形を半径 r で膨らませた角丸正方形の輪郭（半辺は core + r）。

    **どの r でも同じ順序・同じ個数で、対応する点が同じ角度に並ぶ。**
    帯はこれを2本作って橋渡しするだけで作れる、というのがこの形の理由。
    角丸長方形を頂点でじかに書くと、太さを変えたとき中ほどが潰れて平行にならない。
    """
    pts = []
    for k in range(4):
        a0 = k * math.pi / 2
        center = (math.cos(a0 + math.pi / 4) * core * math.sqrt(2.0),
                  math.sin(a0 + math.pi / 4) * core * math.sqrt(2.0))
        pts += arc(center, r, a0, a0 + math.pi / 2, CORNER_SEG, ends=True)
    return pts


def add_band(bm, loops):
    """[(輪郭, z), ...] を下から順に橋渡しして、上下を塞いだ閉じた帯を足す。

    輪郭はすべて同じ個数・同じ対応であることが前提（square_loop の性質）。
    """
    rings = [[bm.verts.new((x, y, z)) for (x, y) in pts] for (pts, z) in loops]
    n = len(rings[0])
    for lo, hi in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


def add_ring(bm, outer, inner, z_lo, z_hi):
    """外輪郭と内輪郭を天面・底面・内外の壁で閉じた薄い環を足す。"""
    ot = [bm.verts.new((x, y, z_hi)) for (x, y) in outer]
    ob = [bm.verts.new((x, y, z_lo)) for (x, y) in outer]
    it = [bm.verts.new((x, y, z_hi)) for (x, y) in inner]
    ib = [bm.verts.new((x, y, z_lo)) for (x, y) in inner]
    for i in range(len(outer)):
        j = (i + 1) % len(outer)
        bm.faces.new((ot[i], ot[j], it[j], it[i]))  # 天面
        bm.faces.new((ib[i], ib[j], ob[j], ob[i]))  # 底面
        bm.faces.new((ob[i], ob[j], ot[j], ot[i]))  # 外壁
        bm.faces.new((it[i], it[j], ib[j], ib[i]))  # 内壁

# =====================================================================
# 板の絵（テクスチャ）
# =====================================================================

def _hash(i, j, k):
    """格子の座標から決まる 0..1 の疑似乱数。乱数モジュールは使わない。

    ビルドを何度回しても同じ glb になるようにするため（build_spark と同じ流儀）。
    """
    x = np.sin(i * 127.1 + j * 311.7 + k) * 43758.5453
    return x - np.floor(x)


def _grad_param(u, v):
    """地のグラデーションのパラメータ g（0..1）。

    横は中央が0・左右の端が1（端へ行くほど黄）、縦は余弦で周期的に 0→1→0。
    v について周期的なので、縦にタイルしても継ぎ目が出ない。
    """
    g = 0.55 * np.abs(2.0 * u - 1.0) ** 1.5 + 0.45 * (0.5 - 0.5 * np.cos(2.0 * np.pi * v))
    return np.clip(g, 0.0, 1.0)


def _gradient(g):
    """g=0 ピンク → 0.5 橙 → 1 黄 の折れ線補間。g は任意の形の配列。"""
    g = np.clip(g, 0.0, 1.0)[..., None]
    a, b, c = (np.array(x) for x in (GRAD_PINK, GRAD_ORANGE, GRAD_YELLOW))
    t0 = np.clip(g * 2.0, 0.0, 1.0)
    t1 = np.clip(g * 2.0 - 1.0, 0.0, 1.0)
    return a + (b - a) * t0 + (c - b) * t1


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_plate_texture():
    """板の絵（タイル1枚）を numpy で作り、(高さ, 幅, 4) の float32 配列で返す。

    1枚 = 板の幅いっぱい（7.68m）x 縦の1周期（3.84m）。**縦は継ぎ目なくタイルする**
    （横はタイルしない）。地のグラデーションも結晶モザイクも v の周期に合わせてあるので、
    Godot が UV をずらして流しても切れ目が出ない。

    **ピクセル値は sRGB のまま書く。** 8bit sRGB 画像の pixels は表示値そのもので、
    srgb()（リニア化）を通すと暗く沈む。srgb() は baseColorFactor のような
    「数値で渡す色」専用。行 0 が画像の下（Blender の v=0）。
    """
    px = (np.arange(TEX_W) + 0.5) / TEX_W
    py = (np.arange(TEX_H) + 0.5) / TEX_H
    u, v = np.meshgrid(px, py)              # 形は (TEX_H, TEX_W)。v は上向き
    X, Y = u * TILE_W, v * TILE_H
    g = _grad_param(u, v)
    smooth = _gradient(g)

    # ---- 結晶モザイク: 格子ボロノイ。各セルの種点を揺らし、最寄りの種点の面を塗る ----
    cw, ch = TILE_W / CELLS_X, TILE_H / CELLS_Y
    pi = np.clip(np.floor(X / cw).astype(int), 0, CELLS_X - 1)
    pj = np.floor(Y / ch).astype(int)
    best = np.full(X.shape, np.inf)
    seed_i = np.zeros(X.shape, dtype=int)
    seed_j = np.zeros(X.shape, dtype=int)
    seed_x = np.zeros(X.shape)
    seed_y = np.zeros(X.shape)
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            ci = np.clip(pi + di, 0, CELLS_X - 1)   # i は端でクランプ（横はタイルしない）
            cj = (pj + dj) % CELLS_Y                # j は wrap（縦は継ぎ目なし）
            sx = (ci + 0.5 + (_hash(ci, cj, 0.0) - 0.5) * 0.8) * cw
            # 距離は wrap 前の位置で測る（wrap 後だと上下の端で遠い種点を拾う）
            sy = (pj + dj + 0.5 + (_hash(ci, cj, 1.0) - 0.5) * 0.8) * ch
            d = (X - sx) ** 2 + (Y - sy) ** 2
            hit = d < best
            best = np.where(hit, d, best)
            seed_i = np.where(hit, ci, seed_i)
            seed_j = np.where(hit, cj, seed_j)
            seed_x = np.where(hit, sx, seed_x)
            seed_y = np.where(hit, sy, seed_y)
    # 面の色は種点の位置のグラデーションを少しずらしたもの。面ごとに明るさも変えて結晶に見せる
    gs = _grad_param(seed_x / TILE_W, (seed_y / TILE_H) % 1.0)
    gs = gs + (_hash(seed_i, seed_j, 2.0) - 0.5) * 0.40
    facet = _gradient(gs) * (0.90 + 0.20 * _hash(seed_i, seed_j, 3.0))[..., None]
    base = np.clip(facet, 0.0, 1.0) * 0.65 + smooth * 0.35

    # ---- 白い山型: 3列。縦は周期 TILE_H で wrap して判定する ----
    alpha = np.zeros(X.shape)
    half = EDGE_AA / 2.0
    for cx, apex in CHEV_COLUMNS:
        dx = np.abs(X - cx)
        center_y = apex - CHEV_SLOPE * dx
        # 帯は center_y から下へ CHEV_THICK。縁の両側でにじませるので [-P/2, P/2) へ寄せて符号付きで測る
        d = (center_y - Y + TILE_H / 2.0) % TILE_H - TILE_H / 2.0
        a = (_smoothstep(-half, half, d)
             * _smoothstep(-half, half, CHEV_THICK - d)
             * _smoothstep(-half, half, CHEV_HALF_W - dx))
        alpha = np.maximum(alpha, a)
    rgb = base * (1.0 - alpha[..., None]) + alpha[..., None]

    out = np.ones((TEX_H, TEX_W, 4), dtype=np.float32)
    out[..., :3] = rgb
    return out


def save_png(arr, path, name):
    """(高さ, 幅, 4) の float 配列を PNG として保存する。保存した画像を返す。"""
    h, w = arr.shape[:2]
    old = bpy.data.images.get(name)
    if old is not None:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, width=w, height=h, alpha=False)
    img.pixels.foreach_set(arr.reshape(-1))
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img


# =====================================================================
# パーツ
# =====================================================================

def circle_loop(cx, cy, r):
    return [(cx + math.cos(2 * math.pi * k / BOLT_SEG) * r,
             cy + math.sin(2 * math.pi * k / BOLT_SEG) * r) for k in range(BOLT_SEG)]


def build_frame():
    """銀色の細い枠。外輪郭と内輪郭は同じ芯を太さ違いで膨らませたもの（square_loop の性質）。

    四隅のボルトは枠の幅の中心（角の円弧の中心から FRAME_BAND/2 の位置）に置く。
    枠と同じメッシュへ足すので、マテリアルは1つで済む。
    """
    bm = bmesh.new()
    add_ring(bm, square_loop(CORE_SQ, CORNER_R), square_loop(CORE_SQ, CORNER_R - FRAME_BAND),
             0.0, FRAME_TOP)
    off = (CORNER_R - FRAME_BAND / 2) / math.sqrt(2.0)
    for sx in (-1, 1):
        for sy in (-1, 1):
            c = (sx * (CORE_SQ + off), sy * (CORE_SQ + off))
            add_band(bm, [(circle_loop(*c, BOLT_R), FRAME_TOP),
                          (circle_loop(*c, BOLT_R), BOLT_TOP)])
    obj = finish(bm, "Frame")
    return paint(obj, make_mat("PadFrame", FRAME_COLOR, FRAME_EMISSION,
                               metallic=0.2, roughness=0.35))


def build_plate(img):
    """平らな四角1枚。絵はすべてテクスチャで、メッシュに凹凸は無い。

    UV: u は板の幅で 0..1、v は板の縦で 0..V_TILES（タイルが縦に V_TILES 枚並ぶ）。
    boost_panel.gdshader の tiles と V_TILES を揃えること。
    頂点は反時計回り（+Z が表）。1面だけなので recalc_face_normals の向き判定に頼らない。
    """
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    p = PLATE_HALF
    face = bm.faces.new([bm.verts.new((x, y, PLATE_Z))
                         for (x, y) in ((-p, -p), (p, -p), (p, p), (-p, p))])
    for loop in face.loops:
        x, y, _ = loop.vert.co
        loop[uv].uv = ((x + p) / (2 * p), (y + p) / (2 * p) * V_TILES)
    obj = finish(bm, "Plate")
    mat = make_mat("PadPlate", (1.0, 1.0, 1.0), 1.0, roughness=0.25)
    tree = mat.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    tex = tree.nodes.new("ShaderNodeTexImage")
    tex.image = img
    # Base Color と Emission Color の両方へ繋ぐ。Godot は ALBEDO と EMISSION の両方に
    # この絵を使うので（boost_panel.gdshader）、Blender のプレビューも同じ見え方にする
    tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    tree.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
    return paint(obj, mat)


def build_spark(index):
    """踏んだ瞬間に噴く火花のうち、1色ぶんを1メッシュへ結合する。

    色ごとにメッシュを分けるのは、1メッシュに1マテリアルしか持たせない
    このプロジェクトの流儀のため（頂点カラーも UV も使わない）。
    粒は全体の連番 i を色数で振り分けるので、どの色も板全体に散る。

    方位角を黄金角(2.4rad)で振るのは見た目の都合ではなく必須。
    beacon.gdshader は 1 メッシュに結合された飾りを揺らすのに
    頂点の方位角 atan(x, z) を位相として使うので、方位角が重なると
    粒が同じ位相で揃って動いてしまう（build_item_box.py の Confetti と同じ）。

    傾きも位置も i から決まる式で与える（乱数を使わない）。
    ビルドを何度回しても同じ glb になるようにするため。

    原点は板の中心のまま。Godot 側で scale すると中心から外へ広がる。
    """
    bm = bmesh.new()
    for i in range(index, SPARK_COUNT, len(SPARK_COLORS)):
        a = 2.4 * i
        r = SPARK_RING * (0.45 + 0.18 * (i % 4))
        loc = (math.cos(a) * r, math.sin(a) * r, 0.16 + 0.09 * ((i * 3) % 5))
        rot = mathutils.Euler((a * 1.7, a * 1.1 + 0.6, a), "XYZ").to_matrix().to_4x4()
        matrix = mathutils.Matrix.Translation(loc) @ rot @ \
            mathutils.Matrix.Diagonal((*SPARK_SIZE, 1.0))
        bmesh.ops.create_cube(bm, size=1.0, matrix=matrix)
    name = "Spark%d" % index
    obj = finish(bm, name)
    return paint(obj, make_mat(name, SPARK_COLORS[index], GLOW_EMISSION, roughness=1.0))



# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    root = bpy.data.objects.new("DashPad", None)
    bpy.context.collection.objects.link(root)

    tile = make_plate_texture()
    img = save_png(tile, TILE_PATH, "boost_panel_tile")

    parts = [build_frame(), build_plate(img)]
    parts += [build_spark(i) for i in range(len(SPARK_COLORS))]

    for obj in parts:
        obj.parent = root

    for obj in bpy.data.objects:
        verts = len(obj.data.vertices) if obj.data else 0
        print("object :", obj.name, "verts", verts)
    return tile


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    # export_texcoords=True が必須。False だと UV が書かれず、Plate の絵が貼れない
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH, export_format="GLB", export_yup=True, export_apply=True,
        export_animations=False, export_skins=False,
        export_cameras=False, export_lights=False,
        export_materials="EXPORT", export_texcoords=True,
        use_visible=False, use_selection=False)
    print("saved  :", BLEND_PATH)
    print("export :", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")


def render_previews(out_dir, tile):
    """形の確認用プレビュー。流れは Godot 側なので、ここでは静止した絵が写る。"""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    # MATERIAL だとマテリアルの単色（Base Color の既定値）しか写らず、テクスチャが出ない
    scene.display.shading.color_type = "TEXTURE"
    scene.display.render_aa = "8"
    # **Standard を明示する。** Blender の既定の View Transform（AgX）は
    # 彩度を大きく落とすので、そのままだと配色を判断できない絵が出る
    # （黄がカーキに、ピンクが藤色に見える）。glb に入るのは素の値なので、
    # プレビューも素の値のまま出す
    scene.view_settings.view_transform = "Standard"
    scene.render.resolution_x, scene.render.resolution_y = 640, 640
    scene.render.film_transparent = False

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    cam.data.lens = 50
    scene.camera = cam
    # 真上からの1枚だけ FLAT で撮る。STUDIO は天面に環境光を乗せるので、
    # 見下ろすと色が眠って配色を判断できない。斜めからの2枚は面の向きが要るので STUDIO
    shots = [
        ("three_quarter", (60, 0, -35), 0.05, 15.0, "STUDIO"),
        ("low", (82, 0, -20), 0.05, 15.0, "STUDIO"),
        ("top", (0, 0, 0), 0.05, 14.0, "FLAT"),
    ]
    for name, deg, target_z, dist, light in shots:
        scene.display.shading.light = light
        euler = mathutils.Euler([math.radians(a) for a in deg], "XYZ")
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "boost_panel_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)

    # タイルを縦に2枚積んだ確認用画像。V_TILES=2 のとき板に貼られる並びと同じで、
    # 継ぎ目（上下の境）が目視で確かめられる
    x2 = os.path.join(out_dir, "boost_panel_tile_x2.png")
    save_png(np.concatenate([tile, tile], axis=0), x2, "boost_panel_tile_x2")
    print("render :", x2)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    tile = build()
    export()
    if "--render" in argv:
        # 相対パスはプロジェクト基準で解決する。Blender に渡すとドライブ直下に
        # 書かれてしまうため（build_item_box.py と同じ扱い）
        out_dir = argv[argv.index("--render") + 1]
        if not os.path.isabs(out_dir):
            out_dir = os.path.join(PROJECT, out_dir)
        render_previews(out_dir, tile)


main()
