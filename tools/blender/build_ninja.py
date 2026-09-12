"""忍び装束スキンを一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_ninja.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/ninja.blend       編集元（.gdignore で Godot のインポート対象外）
    assets/character/ninja.glb      Godot が読むモデル

豆型のプロポーション・ボーン・アニメは character_common.py で恐竜きぐるみと共有する。
ここが持つのはメッシュと配色だけなので、ボーン名もクリップ名も恐竜と完全に一致し、
humanoid.gd は Model を差し替えるだけで動く。

顔は恐竜のような丸い穴ではなく**横長のスリット**で、目より下は頭巾がそのまま
覆面になる。スリットを塞ぐ目のまわりも、その上の額当ても、体表をオフセットした
「帯」で作ってある。平たい板だと頭の丸みに負けて下側がめり込む。

装束は一色ではなく、上衣 > 股引 > 頭巾の順に濃くなる3段の藍鉄で塗り分け、
胸には和装の合わせ（V の襟）を入れてある。豆型は一枚布になりやすいので、
色の段と襟・帯・巻き布の「線」だけが重ね着の情報になる。
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from character_common import *  # noqa: E402,F403  骨格・リグ・アニメ・書き出し

BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "ninja.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "character", "ninja.glb")

# ---- 配色 -------------------------------------------------------------
# 生地は藍鉄（黒に寄せた藍）で、実際の忍び装束と同じく**一色ではなく3段**に割る。
# 上衣(Cloth) > 股引(ClothMid) > 頭巾・覆面(ClothDark) の順に濃くすると、
# 豆型の一枚布に「重ね着の層」が出て、遠目でもシルエットが読める。
#
# 真っ黒は明るいマップだと陰影が死んで「穴」に見えるので、生地にも 0 ではない
# 自己発光を入れる。自己発光の色は基本色そのものなので、基本色を濃くしたぶん
# 強度を上げないと発光量まで一緒に落ちる。ここは
#   （濃くする前の基本色 × 旧強度）≒（濃くした基本色 × 新強度）
# になる値にしてあり、暗所での明るさは据え置きのまま昼間だけ色が深くなる。
COLORS = {
    "Cloth": (0.088, 0.106, 0.176),     # 上衣（胴の帯より上・袖・ミトン）
    "ClothMid": (0.062, 0.076, 0.132),  # 股引（帯より下・脚・足袋）
    "ClothDark": (0.038, 0.046, 0.082), # 頭巾・覆面・合わせ・鞘・ポーチ
    "Accent": (0.44, 0.085, 0.115),     # マフラー・帯。臙脂まで落として装束に馴染ませる
    "Metal": (0.30, 0.325, 0.375),      # 額当て・鍔・手甲・手裏剣。光る鋼ではなく黒鉄
    "Wrap": (0.55, 0.495, 0.385),       # 腕と脚の巻き布、柄巻き。晒しではなく汚れた麻
    "Skin": (0.90, 0.66, 0.60),         # 覆面と額当ての間から覗く目のまわり
    "Shine": (0.99, 0.98, 0.97),
    "Pupil": (0.06, 0.05, 0.08),
}
EMISSION = {"Pupil": 0.0, "Cloth": 0.28, "ClothMid": 0.26, "ClothDark": 0.24}
EMISSION_DEFAULT = 0.35
set_palette(COLORS, EMISSION, EMISSION_DEFAULT)

# 生地・金属・巻き布で粗さを変える。Workbench のプレビューには出ないが、
# Godot は glTF の roughness をそのまま使うので、ゲーム内では
# 「つや消しの装束の中で額当てと手裏剣だけ光る」差になる
ROUGHNESS = {"Cloth": 0.82, "ClothMid": 0.82, "ClothDark": 0.86, "Wrap": 0.90,
             "Accent": 0.74, "Metal": 0.30, "Shine": 0.12}
_base_make_mat = make_mat  # noqa: F405  character_common 側の素の生成


def make_mat(name):
    mat = _base_make_mat(name)
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = ROUGHNESS.get(name, 0.45)
    if name == "Metal":
        bsdf.inputs["Metallic"].default_value = 0.85
    return mat


# =====================================================================
# メッシュ
# =====================================================================

LEG = [(0.040, 0.000), (0.060, 0.080), (0.100, 0.112), (0.170, 0.126),
       (0.280, 0.128), (0.400, 0.130), (0.520, 0.134), (0.610, 0.138),
       (0.660, 0.110), (0.680, 0.000)]
# 袖から先のミトン（＝黒い手袋）。恐竜と同じ形
MITT = cap(-0.360, 0.125) + [(-0.325, 0.121), (-0.290, 0.112), (-0.262, 0.098), (-0.245, 0.000)]
# 袖（＝装束の腕）。恐竜のピンクの肌と同じ形だが、生地なので Body 側に入る
SLEEVE = [(-0.295, 0.000), (-0.280, 0.052), (-0.262, 0.078), (-0.240, 0.088),
          (-0.100, 0.086), (0.000, 0.090), (0.070, 0.088), (0.105, 0.068), (0.130, 0.000)]

# ---- 顔まわり（体表からのオフセット, 生地の厚み）--------------------------
# 顔穴は恐竜と違って**横長のスリット**にする。円柱カッターを縦に潰して抜くので、
# 開くのは z=1.198〜1.403 だけ。目より下は頭巾がそのまま覆面になり、
# 「目だけ出した忍び」の読みが一発で立つ。
FACE_HOLE_FLAT = 0.50               # 顔穴カッターの縦つぶし率
# 覆面の縁。頭巾の外に薄く重ねた輪で、生地が巻き付いた段差だけを見せる
HEM_Z = (1.090, 1.212)
HEM_OUT, HEM_THICK = HOOD_OUT + 0.008, 0.012
# スリットから覗く目のまわり。スリット(1.198〜1.403)を上下に余裕をもって覆う
EYE_Z = (1.170, 1.442)
EYE_OUT, EYE_THICK = 0.013, 0.008
# 額当て。フード外面(+0.034)より外に出して、頭に巻いた金属板として見せる
PLATE_Z = (1.408, 1.500)
PLATE_OUT, PLATE_THICK = 0.040, 0.014

# 上衣の裾。ここより下は股引（ClothMid）になる。帯(0.755〜0.858)の少し下に置き、
# 上衣が帯の下へ短く出ている和装の重なりを作る
JACKET_HEM_Z = 0.72


def band(name, z0, z1, out, thick, segments=28):
    """体表を out だけ外へオフセットした帯（内側 out-thick 〜 外側 out を占める）。

    平たい円盤ではなく帯にするのは、顔穴のふちが頭の丸みに沿って前後に大きく
    うねるため。平たい板だと下側でボディが手前に出て板がめり込む。
    帯は 360度まわるが、顔穴以外はフードに隠れるので見えない。"""
    pts = [(z, r) for z, r in BODY_PROFILE if z0 <= z <= z1]
    if not pts or pts[0][0] > z0 + 1e-6:
        pts.insert(0, (z0, body_radius(z0)))
    if pts[-1][0] < z1 - 1e-6:
        pts.append((z1, body_radius(z1)))
    obj = lathe(name, offset_profile(pts, out), segments)
    solid = obj.modifiers.new("Solidify", 'SOLIDIFY')
    solid.thickness, solid.offset = thick, -1.0
    apply_mods(obj)
    return obj


def on_band(azimuth, z, out):
    """帯の上の点と、そこへ向く Euler。目・ハイライトを同じ曲面へ乗せる。"""
    r = body_radius(z) + EYE_OUT + out
    return (r * math.sin(azimuth), -r * math.cos(azimuth), z), (0.0, 0.0, azimuth)


def torus(name, major, minor, major_seg=24, minor_seg=10):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor,
                                     major_segments=major_seg, minor_segments=minor_seg)
    obj = bpy.context.object
    obj.name = name
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return obj


def paint(obj, name):
    """1色で塗る。append だけでは駄目で、必ずスロットを空にしてから入れること。

    ブーリアンや Solidify を適用したメッシュ、材質を持たないもの同士を join した
    メッシュには**空のマテリアルスロット**が残っていることがある。そこへ append
    すると色は index 1 に入るのに面は index 0（空＝既定のグレー）を向いたままで、
    塗ったつもりのパーツが灰色に化ける。"""
    obj.data.materials.clear()
    obj.data.materials.append(make_mat(name))
    for poly in obj.data.polygons:
        poly.material_index = 0
    return obj


def paint_split(obj, lower, upper, z):
    """高さ z を境に 2色へ塗り分ける。上衣の裾を胴に直接引くのに使う。

    面の中心で判定するので、境界はいちばん近い輪郭リングの高さにぴたりと吸着し、
    水平に一周する。JACKET_HEM_Z=0.72 は BODY_PROFILE のリング z=0.731 に吸い付く。"""
    obj.data.materials.clear()
    obj.data.materials.append(make_mat(lower))
    obj.data.materials.append(make_mat(upper))
    for poly in obj.data.polygons:
        poly.material_index = 1 if poly.center.z >= z else 0
    return obj


def build_body():
    """装束の生地。上衣（帯の上）と股引（帯の下）を塗り分けた胴に、袖・脚・足袋が付く。

    材質が複数あるので恐竜のように material_index を 0 で潰さず、
    パーツごとに色を塗ってから結合する（join がスロットを引き継ぐ）。"""
    body = paint_split(lathe("Body", BODY_PROFILE, segments=24),
                       "ClothMid", "Cloth", JACKET_HEM_Z)
    parts = []
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        loc, rot = arm_transform(sx)
        parts.append(paint(bake(lathe("Sleeve" + side, SLEEVE, 16), loc=loc, rot=rot), "Cloth"))
        parts.append(paint(bake(lathe("Mitt" + side, MITT, 16), loc=loc, rot=rot), "Cloth"))
        parts.append(paint(bake(lathe("Leg" + side, LEG, 16),
                                loc=(HIP_X * sx, 0.0, 0.0), rot=(0.0, -0.05 * sx, 0.0)),
                           "ClothMid"))
        parts.append(paint(ball("Boot" + side, (HIP_X * sx, -0.062, 0.106),
                                (0.150, 0.215, 0.106)), "ClothMid"))
        # 足袋のつま先の割れ。ブーツを2つに分けるより、暗い薄板を差し込む方が
        # 形が崩れず、subsurf をかけても割れ目が残る。ブーツ表面より少し出さないと
        # 同系色どうしで溶けて見えなくなる
        parts.append(paint(ball("Toe" + side, (HIP_X * sx, -0.168, 0.100),
                                (0.021, 0.092, 0.101)), "ClothDark"))
    join_into(body, parts)
    return body


def build_hood():
    """頭をすっぽり覆う忍びの頭巾。目の高さだけ横長のスリットに抜く。

    スリットより下は頭巾がそのまま覆面になるので、口を隠す別パーツは要らない。
    代わりに縁の輪（HEM）を外側へ薄く重ねて、生地が巻き付いた段差だけを見せる。"""
    profile = [(z, r) for z, r in BODY_PROFILE if z >= HOOD_Z0]
    profile.insert(0, (HOOD_Z0, body_radius(HOOD_Z0)))
    hood = lathe("Hood", offset_profile(profile, HOOD_OUT), segments=24)
    solid = hood.modifiers.new("Solidify", 'SOLIDIFY')
    solid.thickness, solid.offset = HOOD_THICK, -1.0

    # 円柱を寝かせてから縦に潰す（bake は scale -> rot -> loc の順に効くので、
    # 回転の**あと**に潰すには bake を分ける必要がある）
    bpy.ops.mesh.primitive_cylinder_add(radius=FACE_HOLE_R, depth=1.2, vertices=28)
    cutter = bpy.context.object
    bake(cutter, rot=(math.radians(90), 0.0, 0.0))
    bake(cutter, scale=(1.0, 1.0, FACE_HOLE_FLAT))
    bake(cutter, loc=(0.0, -0.5, FACE_Z))
    hole = hood.modifiers.new("Hole", 'BOOLEAN')
    hole.operation, hole.object, hole.solver = 'DIFFERENCE', cutter, 'EXACT'
    apply_mods(hood)
    bpy.data.objects.remove(cutter, do_unlink=True)
    cleanup(hood)

    # 頭巾の後ろに垂れる布。フードの外側に重ねた帯の前半分を落として背面だけ残す
    drape = band("Drape", 1.030, 1.300, HOOD_OUT + HOOD_THICK * 0.30, 0.012, segments=24)
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(0.0, -1.02, 1.16))
    front = bpy.context.object
    cut = drape.modifiers.new("Front", 'BOOLEAN')
    cut.operation, cut.object, cut.solver = 'DIFFERENCE', front, 'EXACT'
    apply_mods(drape)
    bpy.data.objects.remove(front, do_unlink=True)
    cleanup(drape)

    hem = band("Hem", HEM_Z[0], HEM_Z[1], HEM_OUT, HEM_THICK, segments=24)
    for part in (hood, drape, hem):
        paint(part, "ClothDark")
    join_into(hood, [drape, hem])
    for poly in hood.data.polygons:
        poly.use_smooth = True
    return hood


def build_face():
    """スリットから覗く顔と、その上の額当て。

    どちらも Chest に剛体バインドするので、頭を振っても顔が本体からズレない。"""
    eyes = paint(band("EyeBand", EYE_Z[0], EYE_Z[1], EYE_OUT, EYE_THICK), "Skin")
    plate = paint(band("Plate", PLATE_Z[0], PLATE_Z[1], PLATE_OUT, PLATE_THICK), "Metal")

    parts = [plate]
    pupil, shine_mat = make_mat("Pupil"), make_mat("Shine")
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        pos, rot = on_band(0.245 * sx, 1.305, -0.006)
        eye = ball("Eye" + side, pos, (0.036, 0.026, 0.042), rot=rot)
        eye.data.materials.append(pupil)
        pos, rot = on_band(0.290 * sx, 1.324, 0.012)
        shine = ball("Shine" + side, pos, (0.014, 0.011, 0.015), rot=rot)
        shine.data.materials.append(shine_mat)
        parts += [eye, shine]

    join_into(eyes, parts)
    eyes.name = "Face"
    for poly in eyes.data.polygons:
        poly.use_smooth = True
    return set_group(eyes, {"Chest": 1.0})


def build_sword():
    """背中の刀。ローカル +Z が切っ先。鞘・鍔・柄を別マテリアルで組んでから
    まとめて背中へ寝かせる。

    豆型は上下に細るので、まっすぐな刀を背中に「浮かせずに」置くことはできない。
    背負う高さ(SWORD_Y)は**上端がぎりぎり出る**値にしてあり、中央は半分体に
    埋まる。埋まるぶんは見えないので害はなく、逆に「背中に括り付けてある」
    密着感が出る。伸ばしたり寝かせたりすると両端が背中から浮いて剥がれて見える"""
    saya = paint(lathe("Saya", cap(-0.215, 0.027, 5) +
                       [(-0.070, 0.027), (0.015, 0.025), (0.052, 0.024), (0.058, 0.000)],
                       12), "ClothDark")
    tsuba = paint(ball("Tsuba", (0.0, 0.0, 0.064), (0.046, 0.046, 0.007), segments=12), "Metal")
    tsuka = paint(lathe("Tsuka", [(0.068, 0.000), (0.076, 0.018), (0.098, 0.022),
                                  (0.155, 0.023), (0.182, 0.019), (0.192, 0.000)], 12), "Wrap")
    sword = join_into(saya, [tsuba, tsuka])
    sword.name = "Sword"
    bake(sword, rot=(0.0, math.radians(20.0), 0.0))
    return bake(sword, loc=(0.0, 0.435, 1.075))


def build_shuriken():
    """帯の正面に留めた手裏剣。ローカル XY 平面に寝かせて作り、
    surface_frame でお腹の法線へ向ける。"""
    hub = ball("Hub", (0.0, 0.0, 0.0), (0.026, 0.026, 0.011), segments=10)
    blades = []
    for i in range(4):
        blade = cone("Blade%d" % i, 0.020, 0.064, segments=6)
        # cone のローカル +Z が先端。X 軸まわりに 90度倒して XY 平面へ寝かせ、
        # Z 軸まわりに 90度ずつ回して4方向へ生やす
        bake(blade, rot=(math.radians(90.0), 0.0, math.radians(90.0 * i)))
        blades.append(blade)
    star = paint(join_into(hub, blades), "Metal")
    star.name = "Shuriken"
    pos, normal, frame = surface_frame(0.815, 0.0)
    return bake(star, loc=tuple(pos + normal * 0.055), rot=frame)


def build_lapel(sx):
    """上衣の合わせ（打ち合わせ）。胸を斜めに横切って V を作る。

    薄い板を胸に貼ると、板は平らなまま胴は丸いので端が体へ潜って消える。
    そこで体表に沿う帯(band)を一周ぶん作ってから、斜めのスラブでブーリアンの
    INTERSECT を掛け、**曲面に乗ったまま斜めの縁**を切り出す。

    帯の上端(1.06)はマフラーと頭巾の裏、下端(0.80)は帯(Sash)の裏に隠れるので、
    切り口の水平なふちは表に出ない。合わせは胸だけに見えて上下は布へ吸い込まれる。
    浮かせ量は Sash(0.010)より小さい 0.008 にすること。大きいと帯を突き抜ける。

    スラブは前後を貫くので背面にも同じ斜めが出るが、左右が交差して襷掛けに
    見えるのでそのまま残す。"""
    side = "L" if sx > 0 else "R"
    shell = band("Lapel" + side, 0.790, 1.060, 0.009, 0.016, segments=30)
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    slab = bpy.context.object
    # 幅は着物の襟なみに広く取る。細い帯にすると Subsurf に丸め込まれて
    # 「傷」のような数本の線に痩せ、布の重なりに見えない
    bake(slab, scale=(1.0, 1.2, 0.085))
    bake(slab, rot=(0.0, math.radians(-40.0) * sx, 0.0))
    bake(slab, loc=(0.100 * sx, -0.10, 0.904))
    strip = shell.modifiers.new("Strip", 'BOOLEAN')
    strip.operation, strip.object, strip.solver = 'INTERSECT', slab, 'EXACT'
    apply_mods(shell)
    bpy.data.objects.remove(slab, do_unlink=True)
    cleanup(shell)
    return set_group_ramp(paint(shell, "ClothDark"), "Spine", "Chest", 0.95, 1.06)


def build_costume():
    """固定色の装備。パーツごとに追従ボーンが違うので、結合前に頂点グループを入れる。"""
    parts = []

    # --- マフラー（首）。暗い装束の中で一番よく目立つ面積なので大きめに巻く。
    # 帯とは z を大きく離すこと。近づけると赤どうしが繋がって浮き輪になる
    # 太さと高さは胸元の空きを決める。合わせ(build_lapel)が見えるのは
    # マフラーの下端と帯の上端に挟まれた帯域だけなので、ここを太らせると襟が消える
    scarf = paint(bake(torus("Scarf", 0.406, 0.036, 26, 10), loc=(0.0, 0.0, 1.018)), "Accent")
    parts.append(set_group_ramp(scarf, "Spine", "Chest", 0.95, 1.06))
    # 首の後ろから**背中へ流れる**2本の帯。真下へ垂らすと豆型の丸みに負けて
    # 腰のあたりでしか表に出ず、帯（Sash）の垂れと見分けが付かなくなるので、
    # 後ろへ長く伸ばして首のすぐ後ろで体から離す
    for i, sx in enumerate((1.0, -1.0)):
        tail = ball("ScarfTail%d" % i, (0.100 * sx, 0.455, 0.995), (0.038, 0.190, 0.019),
                    rot=(math.radians(-45.0), 0.0, math.radians(-12.0 * sx)))
        parts.append(set_group(paint(tail, "Accent"), {"Chest": 1.0}))

    # 額当ての結び紐。頭巾は一色の卵型で間が持たないので、後頭部に明るい紐を
    # 2本垂らして視線の止まる所を作る
    for i, sx in enumerate((1.0, -1.0)):
        ribbon = ball("Ribbon%d" % i, (0.055 * sx, 0.375, 1.335), (0.026, 0.018, 0.115),
                      rot=(math.radians(30.0), 0.0, math.radians(-8.0 * sx)))
        parts.append(set_group(paint(ribbon, "Wrap"), {"Chest": 1.0}))

    # --- 帯（腰）と結び目・垂れ。Hips(0.62〜0.86) と Spine(0.86〜1.06) の境目に
    # かかるので、ボーンは高さでなめらかに振り分ける
    sash = paint(band("Sash", 0.748, 0.842, 0.010, 0.016, segments=26), "Accent")
    parts.append(set_group_ramp(sash, "Hips", "Spine", 0.76, 0.90))
    knot = paint(ball("Knot", (0.0, -(body_radius(0.808) + 0.024), 0.808),
                      (0.062, 0.038, 0.048)), "Accent")
    parts.append(set_group(knot, {"Hips": 1.0}))
    for i, sx in enumerate((1.0, -1.0)):
        end = paint(ball("SashEnd%d" % i, (0.0, 0.0, 0.0), (0.030, 0.016, 0.082)), "Accent")
        bake(end, rot=(math.radians(-10.0), 0.0, math.radians(-9.0 * sx)))
        bake(end, loc=(0.046 * sx, -(body_radius(0.735) + 0.028), 0.710))
        parts.append(set_group(end, {"Hips": 1.0}))
    parts.append(set_group(build_shuriken(), {"Hips": 1.0}))
    # 上衣の合わせ。マフラーの下から出て帯へ差し込まれる位置に置き、
    # 「巻いた布」ではなく「前で合わせて帯で留めた上衣」として読ませる
    parts += [build_lapel(1.0), build_lapel(-1.0)]

    # --- 背中の刀。Chest にまるごと乗せる（振り向きに一体で付いてくる）
    parts.append(set_group(build_sword(), {"Chest": 1.0}))

    # --- 手裏剣ポーチ（右腰）。az は正面が 0、+X 側が正なので負値で右へ
    pos, normal, frame = surface_frame(0.745, -1.30)
    pouch = paint(ball("Pouch", tuple(pos + normal * 0.028), (0.056, 0.036, 0.050), rot=frame),
                  "ClothDark")
    parts.append(set_group(pouch, {"Hips": 1.0}))

    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        loc, rot = arm_transform(sx)
        # 手甲。少ない分割数で角を残し、金属板らしくする。
        # 袖(SLEEVE)とミトンの継ぎ目がちょうど WRIST_Z なので、ここで隠れる
        bracer = lathe("Bracer" + side, [(-0.050, 0.000), (-0.046, 0.108), (-0.028, 0.122),
                                         (0.028, 0.122), (0.046, 0.108), (0.050, 0.000)], 10)
        bake(bracer, loc=(0.0, 0.0, WRIST_Z))
        parts.append(set_group(paint(bake(bracer, loc=loc, rot=rot), "Metal"),
                               {"UpperArm." + side: 1.0}))
        # 前腕の巻き布。手甲のすぐ上に2本だけ巻く（腕ぜんぶを明色にすると
        # 「グレーのシャツ」に見えて装束が読めなくなる）
        for i, az in enumerate((-0.205, -0.155)):
            cuff = torus("ArmWrap%s%d" % (side, i), 0.094, 0.016, 14, 8)
            bake(cuff, loc=(0.0, 0.0, az))
            parts.append(set_group(paint(bake(cuff, loc=loc, rot=rot), "Wrap"),
                                   {"UpperArm." + side: 1.0}))
        # 脚絆（ふくらはぎと足首の巻き布）
        for i, (lz, major) in enumerate(((0.430, 0.134), (0.300, 0.130))):
            wrap = torus("LegWrap%s%d" % (side, i), major, 0.021, 14, 8)
            bake(wrap, loc=(0.0, 0.0, lz))
            bake(wrap, loc=(HIP_X * sx, 0.0, 0.0), rot=(0.0, -0.05 * sx, 0.0))
            bone = "Shin." + side if lz < 0.36 else "Thigh." + side
            parts.append(set_group(paint(wrap, "Wrap"), {bone: 1.0}))
        # 草鞋の緒。足袋の甲を横切る一本。足元まで生地と同色だと影で塊になるので、
        # ブーツより少しだけ幅広にして、甲と両側面から縁が覗くようにする
        strap = ball("Strap" + side, (HIP_X * sx, -0.130, 0.165), (0.152, 0.022, 0.062))
        parts.append(set_group(paint(strap, "Wrap"), {"Foot." + side: 1.0}))

    costume = parts[0]
    join_into(costume, parts[1:])
    costume.name = "Costume"
    for poly in costume.data.polygons:
        poly.use_smooth = True
    return costume


# =====================================================================
# 組み立て
# =====================================================================

def build():
    clear_scene()
    body, hood = build_body(), build_hood()
    face, costume = build_face(), build_costume()

    rig = build_armature()
    parent_to_rig(rig, body, 'ARMATURE_AUTO')
    snap_head_to_chest(body)

    # 頭巾は自動ウェイトだと内側の面がボディと干渉するので手で振り分けてから合流する
    set_group_ramp(hood, "Spine", "Chest", HOOD_Z0, 1.18)
    join_into(body, [hood])
    cleanup(body)

    parent_to_rig(rig, face, 'ARMATURE')
    parent_to_rig(rig, costume, 'ARMATURE')

    for obj in (body, face, costume):
        for poly in obj.data.polygons:
            poly.use_smooth = True
        sub = obj.modifiers.new("Subsurf", 'SUBSURF')
        sub.levels = sub.render_levels = 1
        # スキニングを保つため、Subsurf はアーマチュアより前に置いて先に焼き込む
        obj.modifiers.move(obj.modifiers.find("Subsurf"), 0)

    made = [make_action(rig, name, keys, loop) for name, (keys, loop) in CLIPS.items()]
    push_nla(rig, made)
    apply_pose(rig, {})
    bpy.context.scene.frame_set(0)
    return rig


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export_glb(BLEND_PATH, GLB_PATH)
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1], "ninja")


main()
