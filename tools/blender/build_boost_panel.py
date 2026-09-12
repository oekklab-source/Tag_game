"""ダッシュパネル（レインボーロードのダッシュ板）を一から組み立てて glTF に書き出す。

    blender -b -P tools/blender/build_boost_panel.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/boost_panel.blend   編集元（.gdignore で Godot のインポート対象外）
    assets/gimmicks/boost_panel.glb   Godot が読むモデル

**8m 角の正方形で、90度回しても同じ形（4回対称）。** ベルトコンベアだった頃は
搬送方向に逆らうと通り抜けられなかったが、今は踏んだ人自身の進行方向へ蹴り出すので
四方から乗れる（boost_panel.gd を参照）。5m x 10m の長方形だと
「長い方が正面」に見えて仕様と食い違うので、正方形にして四方を等価にしてある。
山型も4方向ぶん置く。片方向の矢印にすると、逆から乗った人が
「矢印と逆へ加速する」ことになり、見た目が仕様に嘘をつく。

配色は中心から外へ 1周ぶんの虹:
    Wave0 中心の板（マゼンタ）
    Wave1..4 四方へ向かう山型（赤・橙・黄・緑）
    Wave5 外周の枠（シアン）
番号 = 中心からの距離。boost_panel.gd が番号順に位相を遅らせるので、
光の波が中心から四方へ同時に広がる
（このプロジェクトのギミックはアニメーションを焼かずスクリプトで動かす）。

輪郭はぜんぶ「同じ芯を太さ違いで膨らませると点が同じ順序・同じ個数で並ぶ」性質
（ミンコフスキー和）だけで作ってある。square_loop は正方形を、chevron_loop は
V字の折れ線を膨らませたもので、どちらも太さを変えるだけで平行な内側の輪郭が
そのまま得られる。おかげで細くした輪郭を天面に重ねるだけで面取りになり、
bevel を掛けずに丸みが出る。

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

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "boost_panel.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "boost_panel.glb")

# ---- 寸法（当たり判定 BoxShape3D(8, 1.6, 8) に合わせる。Blender は Z-up・単位 m・地面 z=0）----
SIDE = 8.0
HALF = SIDE / 2                  # 4.00
CORNER_R = 0.90                  # 角の丸み
CORE_SQ = HALF - CORNER_R        # 芯の正方形の半辺 3.10。膨らませる前の骨格
CORNER_SEG = 6                   # 角1つあたりの分割数

BASE_TOP = 0.06                  # 台座の天面
WAVE_BOTTOM = 0.04               # 意匠は台座に少し食い込ませる（z ファイティング避け）
WAVE_SHOULDER = 0.09             # ここから上が面取り
WAVE_TOP = 0.12                  # 全高。段差にならない高さに留めること
CHAMFER = 0.030                  # 天面を細める量

FRAME_OUTER = CORNER_R - 0.06    # 外周の枠。台座の縁を細く残す（半辺 3.94）
FRAME_BAND = 0.20
FRAME_INNER = FRAME_OUTER - FRAME_BAND  # 半辺 3.74。山型はこの内側に収めること

CENTER_CORE = 0.45               # 中心の板。芯 0.45 + 丸み 0.27 = 半辺 0.72
CENTER_R = 0.27

# 山型。**4方向ぶん置くので、隣の向きの山型と対角線上でぶつからないことが効く。**
# 先端の中心 (w, apex - sweep) から対角線 y=x までの距離は
# (apex - sweep - w)/√2 なので、これが CHEV_HALF + 余白 を超える w しか取れない。
# 腕を45度にすると w < (apex - 余白)/2 まで痩せて、正方形の縁が大きく余る。
# **浅い腕（sweep = 0.62w）にすると同じ apex で 1.6 倍幅が取れる**ので、
# 板いっぱいに広がる山型になる（マリオカートのダッシュ板も浅く広い）
CHEV_SWEEP = 0.62                # 腕の後退量 / 幅。小さいほど浅く広い山型になる
CHEV_HALF = 0.20                 # 帯の半分の太さ（= 0.40m）
CHEVRONS = [
    (1.30, 0.46),  # (頂点の y, 腕の半分の幅)
    (2.02, 0.90),
    (2.75, 1.34),
    (3.47, 1.78),
]

# 風の軌跡。山型は四方を向いているので**対角線の楔だけが空く**。
# そこへ外向きの流線を並べると、角へ吹き抜ける速度線になる
WIND_Z = 0.075                   # 台座のすぐ上に敷く（山型より低く）
WIND_HALF = 0.10
WIND_SEG = 8
WINDS = [                        # (対角線に沿った始点, 終点)
    (2.80, 3.35),
    (3.50, 4.05),
    (4.20, 4.75),
]

SPARK_COUNT = 24
SPARK_SIZE = (0.18, 0.18, 0.022)
SPARK_RING = 3.0                 # 火花を散らす半径の上限


def srgb(r, g, b):
    """画面で見える色（sRGB）を、glTF が要求する**リニア**値へ直す。

    **ここを通さないと色が1段明るく淡くなって出る。** glTF の baseColorFactor は
    リニアなので、Godot は読み込んだ値を sRGB へ encode して albedo_color にする。
    world_data.gd の ZONE_COLORS（Godot の Color = sRGB）と同じ数字を
    そのまま書くと、ビビッドオレンジのつもりが薄い山吹になる。
    """
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                 for c in (r, g, b))


# ---- 配色（**すべて sRGB で書く**。world_data.gd の ZONE_COLORS と直接見比べられる） ----
# 中心から外へ色相を1周ぶん回す。順番を入れ替えると虹に見えなくなるので、
# 段ごとの色は「中心からの距離」の順に並べたまま触ること
BASE_COLOR = srgb(0.08, 0.05, 0.16)  # 濃紺紫。虹を最大に立たせる下地
WAVE_COLORS = [
    srgb(1.00, 0.24, 0.86),  # Wave0 中心の板: マゼンタ
    srgb(1.00, 0.16, 0.20),  # Wave1 山型: 赤
    srgb(1.00, 0.52, 0.04),  # Wave2 山型: 橙
    srgb(1.00, 0.88, 0.12),  # Wave3 山型: 黄
    srgb(0.32, 0.94, 0.24),  # Wave4 山型: 緑
    srgb(0.12, 0.82, 1.00),  # Wave5 外周の枠: シアン（HUD の「ブースト！」色）
]
# 風は無彩色に近い白青。虹の中で色を主張させると段が1本増えたようにしか見えない
WIND_COLOR = srgb(0.85, 0.96, 1.00)
# 火花は3色。1メッシュに1マテリアルしか持たせない流儀なので、色ごとにメッシュを分ける
SPARK_COLORS = [
    srgb(1.00, 0.86, 0.30),  # 金
    srgb(0.30, 0.95, 1.00),  # シアン
    srgb(1.00, 0.36, 0.86),  # マゼンタ
]
# glb 側の自己発光は控えめにしておく。実際の明るさは Godot が波として上書きする
WAVE_EMISSION = 0.5
BASE_EMISSION = 0.03
# 風と火花は Godot 側で beacon.gdshader（加算合成）に差し替わる。
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


def rotate(pts, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return [(x * ca - y * sa, x * sa + y * ca) for (x, y) in pts]


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


def chevron_loop(apex, w, half, quarter=0):
    """山型の帯1本の輪郭。頂点 (0, apex) から (±w, apex - CHEV_SWEEP*w) へ下る V を太さ half で膨らませる。

    **square_loop と同じ性質を持たせてある。** half を変えても点の順序・個数・
    対応が変わらないので、細くした輪郭を天面に重ねるだけで面取りになる。
    頂点の折れは2辺の法線の和（真上）へ、寄り角のぶん伸ばした距離で継ぐ（マイター）。
    先端は半円で丸める（ポップな当たりにするため）。

    quarter は 90 度単位の回し。0..3 で四方ぶんの山型になる。
    """
    sweep = CHEV_SWEEP * w
    arm = math.hypot(w, sweep)
    n_right = (sweep / arm, w / arm)  # 右腕の外向き法線
    n_left = (-sweep / arm, w / arm)  # 左腕の外向き法線
    miter = half * arm / w            # 頂点で真上へ伸ばす距離
    left = (-w, apex - sweep)
    right = (w, apex - sweep)
    a_right = math.atan2(w, sweep)          # 右先端キャップの開始角（= n_right の向き）
    a_left = math.atan2(w, -sweep)          # 左先端キャップの終了角（= n_left の向き）
    pts = [
        (left[0] + n_left[0] * half, left[1] + n_left[1] * half),
        (0.0, apex + miter),
        (right[0] + n_right[0] * half, right[1] + n_right[1] * half),
    ]
    pts += arc(right, half, a_right, a_right - math.pi, CORNER_SEG)
    pts += [
        (right[0] - n_right[0] * half, right[1] - n_right[1] * half),
        (0.0, apex - miter),
        (left[0] - n_left[0] * half, left[1] - n_left[1] * half),
    ]
    pts += arc(left, half, a_left + math.pi, a_left, CORNER_SEG)
    return rotate(pts, 90.0 * quarter)


def streak_loop(r0, r1, half, deg):
    """両端が尖った紡錘形の流線。deg 方向の半直線上に、r0 から r1 まで伸びる。"""
    pts = [(r0, 0.0)]
    pts += [(r0 + (r1 - r0) * i / WIND_SEG,
             math.sin(math.pi * i / WIND_SEG) * half) for i in range(1, WIND_SEG)]
    pts += [(r1, 0.0)]
    pts += [(r0 + (r1 - r0) * i / WIND_SEG,
             -math.sin(math.pi * i / WIND_SEG) * half)
            for i in range(WIND_SEG - 1, 0, -1)]
    return rotate(pts, deg)


def add_band(bm, loops):
    """[(輪郭, z), ...] を下から順に橋渡しして、上下を塞いだ閉じた帯を足す。

    輪郭はすべて同じ個数・同じ対応であることが前提（square_loop / chevron_loop の性質）。
    """
    rings = [[bm.verts.new((x, y, z)) for (x, y) in pts] for (pts, z) in loops]
    n = len(rings[0])
    for lo, hi in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])  # 山型の天面は凹だが、n-gon のまま書き出しても分割は乱れない


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
# パーツ
# =====================================================================

def build_base():
    """台座。角丸正方形の押し出し。外周の枠より一回り大きく、縁が細い額縁に見える。"""
    bm = bmesh.new()
    add_band(bm, [(square_loop(CORE_SQ, CORNER_R), 0.0),
                  (square_loop(CORE_SQ, CORNER_R), BASE_TOP)])
    obj = finish(bm, "Base")
    return paint(obj, make_mat("PadBase", BASE_COLOR, BASE_EMISSION, roughness=0.5))


def build_wave(index):
    """虹の1段。中心からの距離の順に Wave0..5。

    形は段によって違う（中心の板・四方の山型・外周の枠）が、
    **boost_panel.gd は番号順に位相を遅らせるだけ**なので、
    番号と中心からの距離の対応さえ守れば波は外向きに流れる。
    ここを裏返すと波が内向きになり、「進め」ではなく「吸い込む板」に見える。
    """
    bm = bmesh.new()
    if index == 0:
        # 中心の板。角丸正方形をそのまま押し出す
        add_band(bm, [(square_loop(CENTER_CORE, CENTER_R), WAVE_BOTTOM),
                      (square_loop(CENTER_CORE, CENTER_R), WAVE_SHOULDER),
                      (square_loop(CENTER_CORE, CENTER_R - CHAMFER), WAVE_TOP)])
    elif index == len(WAVE_COLORS) - 1:
        # 外周の枠。ここだけ環なので面取りは付けない（縁が細くて効かない）
        add_ring(bm, square_loop(CORE_SQ, FRAME_OUTER), square_loop(CORE_SQ, FRAME_INNER),
                 WAVE_BOTTOM, WAVE_SHOULDER)
    else:
        apex, w = CHEVRONS[index - 1]
        for quarter in range(4):
            add_band(bm, [
                (chevron_loop(apex, w, CHEV_HALF, quarter), WAVE_BOTTOM),
                (chevron_loop(apex, w, CHEV_HALF, quarter), WAVE_SHOULDER),
                (chevron_loop(apex, w, CHEV_HALF - CHAMFER, quarter), WAVE_TOP),
            ])
    name = "Wave%d" % index
    obj = finish(bm, name)
    return paint(obj, make_mat(name, WAVE_COLORS[index], WAVE_EMISSION, roughness=0.3))


def build_wind(index):
    """風の軌跡。対角線の楔に外向きの流線を1本ずつ、四隅ぶん。

    Godot 側は加算合成の unshaded・cull_disabled で描くので、厚みゼロの板1枚で足りる
    （build_item_box.py の Burst と同じ考え方）。
    """
    r0, r1 = WINDS[index]
    bm = bmesh.new()
    for k in range(4):
        pts = streak_loop(r0, r1, WIND_HALF, 45.0 + 90.0 * k)
        bm.faces.new([bm.verts.new((x, y, WIND_Z)) for (x, y) in pts])
    name = "Wind%d" % index
    obj = finish(bm, name)
    return paint(obj, make_mat(name, WIND_COLOR, GLOW_EMISSION, roughness=1.0))


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

    parts = [build_base()]
    parts += [build_wave(i) for i in range(len(WAVE_COLORS))]
    parts += [build_wind(i) for i in range(len(WINDS))]
    parts += [build_spark(i) for i in range(len(SPARK_COLORS))]

    for obj in parts:
        obj.parent = root

    for obj in bpy.data.objects:
        verts = len(obj.data.vertices) if obj.data else 0
        print("object :", obj.name, "verts", verts)


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH, export_format="GLB", export_yup=True, export_apply=True,
        export_animations=False, export_skins=False,
        export_cameras=False, export_lights=False,
        export_materials="EXPORT", export_texcoords=False,
        use_visible=False, use_selection=False)
    print("saved  :", BLEND_PATH)
    print("export :", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")


def render_previews(out_dir):
    """形の確認用プレビュー。脈動は Godot 側なので、ここでは静止した虹が写る。"""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.color_type = "MATERIAL"
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


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        # 相対パスはプロジェクト基準で解決する。Blender に渡すとドライブ直下に
        # 書かれてしまうため（build_item_box.py と同じ扱い）
        out_dir = argv[argv.index("--render") + 1]
        if not os.path.isabs(out_dir):
            out_dir = os.path.join(PROJECT, out_dir)
        render_previews(out_dir)


main()
