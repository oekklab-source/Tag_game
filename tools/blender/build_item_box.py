"""アイテムボックス（プレゼント箱）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_item_box.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/item_box.blend      編集元（.gdignore で Godot のインポート対象外）
    assets/props/item_box.glb         Godot が読むモデル

見た目は「リボンを掛けたプレゼント箱」。下箱・フタ・十字のリボン・
上面の蝶結びだけで作り、箱そのものの色は包装紙／リボンの2色に絞る。
中身が何かは見せない（「？」も置かない）。

メッシュは4オブジェクト。取得時にフタだけを跳ね上げる開封演出と、
その周りに出るキラキラのために分けてある:

    Base      下箱＋リボン下部
    Lid       フタ＋リボン上部＋蝶結び（原点はフタの中心）
    Burst     足元へ広がる光の輪（開封中だけ出す）
    Confetti  外へ舞う紙吹雪（開封中だけ出す）

Burst / Confetti はふだん Godot 側で隠してあり、開封の瞬間だけ出る。
どちらも加算合成の beacon.gdshader に差し替えて光らせる前提なので、
ここでのマテリアルはプレビュー用のフォールバック。

アニメーションは書き出さない。回転演出・開封演出はどちらも Godot 側
（question_block.gd）の _process()/Tween で行う（AnimationPlayer を増やさない）。
"""

import math
import os
import sys

import bmesh
import bpy
import mathutils

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "item_box.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "props", "item_box.glb")

# ---- 寸法（Blender は Z-up。単位はメートル。原点が箱の中心）----
# question_block.tscn の当たり判定（BoxShape3D 1.7m）に収める。
# 下箱を低くしてフタと蝶結びの分の高さを空け、全体で 1.7m 角に収まるようにする
BODY_W = 1.56       # 下箱の幅・奥行き
BASE_H = 1.12       # 下箱の高さ
BASE_Z = -0.16      # 下箱の中心高さ
LID_W = 1.66        # フタは下箱より一回り大きく被せる
LID_H = 0.24
LID_Z = 0.48
BEVEL = 0.06        # 角の面取り量。角ばりすぎず、ただの球にもならない程度

# Base と Lid を切り分ける高さ（＝フタの下端）。リボンもここで上下に分ける
SEAM = LID_Z - LID_H / 2.0
# リボン上部の下端をこの分だけ下へ潜り込ませる。切り口の面が SEAM で
# ぴたりと同一平面になると Z ファイティングするので、体積として重ねて逃がす
SEAM_OVERLAP = 0.03

# リボンは箱を貫く2枚の板で表現する（実際に巻くのではなく、側面・上面・底面に
# 帯として現れる幅にする）。2枚の上端・外形をわずかにずらすのは、
# 上面／底面の中央で天面が重なって Z ファイティングするのを避けるため
RIBBON_W = 0.26
RIBBON_OUT = 0.845  # フタ(0.83)より外へ出す
RIBBON_TOP = 0.620  # フタ上面(0.60)より上
RIBBON_BOT = -0.750 # 下箱の底(-0.72)より下
RIBBON_SKEW = 0.004 # 2枚目をこの分だけ大きく/高くする

BOW_R = 0.20        # 蝶結びの輪の半径
BOW_TUBE = 0.055
BOW_Z = 0.72        # 輪の中心高さ（結び目の高さに合わせる）

# ---- 開封エフェクト ----
# 箱そのものではなく、開いた瞬間だけ出る飾り。ふだんは Godot 側で隠してある。
CONFETTI_COUNT = 26  # 紙片の枚数。1メッシュに結合するのでいくら増やしてもドローコールは1
CONFETTI_W = 0.085   # 紙片の幅
CONFETTI_L = 0.22    # 紙片の長さ
CONFETTI_T = 0.012   # 紙片の厚み。真の板にすると真横から消えるので薄い直方体にする
BURST_R = 0.86       # 光の輪の内半径。Godot 側で scale して外へ広げる
BURST_W = 0.20       # 輪の太さ
# 輪は箱ではなく地面に敷く。question_block.tscn が Model を y=1.5 に置いていて、
# 箱そのものは（？ブロックと同じく）宙に浮いているため、箱の高さに輪を置くと
# 手前側の弧が箱の正面を横切って「箱が輪切りにされた」ように見えてしまう
BURST_Z = -1.46      # 地面から 4cm。ぴたり 0 にすると床と Z ファイティングする

# ---- 配色 ----
# 包装紙とリボンの2色だけで構成する。色数を増やすより、
# 「リボンの掛かった箱」という形の分かりやすさを優先する
COLORS = {
    "Wrap": (0.80, 0.01, 0.02),   # 深みと重厚感のある濃い赤（クリムゾンレッド）
    "Lid": (0.88, 0.03, 0.04),    # フタの段差を際立たせる同系の濃い赤
    "Ribbon": (0.99, 0.93, 0.80),
    # 開封エフェクト。リボン(0.99,0.93,0.80)に寄せた金〜クリーム白
    "Spark": (1.00, 0.90, 0.62),
}
# 暗い場所でも沈まないよう、全体をわずかに発光させる。
# Spark だけ強いのは、Godot では加算合成シェーダに差し替わるため
# ここの値は Blender プレビュー用のフォールバックだから
EMISSION = {
    "Wrap": 0.12, "Lid": 0.15, "Ribbon": 0.20, "Spark": 1.00,
}


# =====================================================================
# 汎用ヘルパ（build_manhole.py と同じ形。今回使う分だけ）
# =====================================================================

def make_mat(name):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    rgb = COLORS[name]
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.28
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = EMISSION[name]
    mat.diffuse_color = (*rgb, 1.0)
    return mat


def paint(obj, name):
    obj.data.materials.clear()
    obj.data.materials.append(make_mat(name))
    return obj


def lathe(name, profile, segments=24, smooth=True):
    """(高さ, 半径) の並びを Z 軸まわりの回転体にする。半径0の点は極として1頂点に潰す。"""
    bm = bmesh.new()
    rings = []
    for h, r in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, h))])
        else:
            rings.append([bm.verts.new((math.cos(a) * r, math.sin(a) * r, h))
                          for a in (2.0 * math.pi * i / segments for i in range(segments))])
    for lower, upper in zip(rings, rings[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            if len(lower) == 1:
                bm.faces.new((lower[0], upper[j], upper[i]))
            elif len(upper) == 1:
                bm.faces.new((lower[j], lower[i], upper[0]))
            else:
                bm.faces.new((lower[i], lower[j], upper[j], upper[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for poly in mesh.polygons:
        poly.use_smooth = smooth
    return obj


def bake(obj, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    """変換をメッシュに焼き込み、オブジェクト変換を単位に戻す。連続適用で合成できる。"""
    obj.location, obj.rotation_euler, obj.scale = loc, rot, scale
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def set_origin(obj, origin):
    """メッシュを -origin だけ動かし、その分をオブジェクト変換として残す。

    bake() と違い transform_apply しないので、この location は glTF の
    ノード変換として書き出される（export_apply はモディファイアにしか効かない）。
    Godot 側でそのノードを回すと、原点＝ここで指定した点が回転の軸になる。
    """
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.translate(bm, vec=-mathutils.Vector(origin), verts=bm.verts)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    obj.location = origin
    return obj


def box(name, size, loc=(0, 0, 0), rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return bake(obj, loc=loc, rot=rot, scale=size)


def beveled_box(name, size, loc=(0, 0, 0), bevel=BEVEL, segments=3):
    """面取りした直方体。bevel を先に掛けてから移動するので、辺の丸みが等幅になる。"""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=mathutils.Vector(size), verts=bm.verts)
    if bevel > 0.0:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=bevel, segments=segments, affect='EDGES')
    bmesh.ops.translate(bm, vec=mathutils.Vector(loc), verts=bm.verts)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


def torus(name, radius, tube, segments=14, ring=10):
    """XY 平面に寝たドーナツ。lathe の profile を一周させて閉じる（重複頂点は cleanup で潰す）。"""
    profile = [(math.sin(2.0 * math.pi * i / ring) * tube,
                radius + math.cos(2.0 * math.pi * i / ring) * tube)
               for i in range(ring + 1)]
    return cleanup(lathe(name, profile, segments))


def join_into(target, others):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in others:
        obj.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()
    return target


def cleanup(obj):
    """結合で出た重複頂点・不正な面を掃除する（glTF の検証警告対策）。"""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.validate(verbose=False)
    obj.data.update()
    return obj


# =====================================================================
# パーツ
# =====================================================================

def build_box_part():
    """下箱。包装紙の色ひとつで塗る。"""
    return paint(beveled_box("BoxPart", (BODY_W, BODY_W, BASE_H), loc=(0, 0, BASE_Z)), "Wrap")


def build_lid_part():
    """一回り大きく被せるフタ。ここが乗ることで「箱」ではなく「贈り物」に見える。"""
    return paint(beveled_box("LidPart", (LID_W, LID_W, LID_H),
                             loc=(0, 0, LID_Z), bevel=0.04), "Lid")


def build_ribbon(z_lo, z_hi, suffix):
    """箱を十字に貫く2枚の帯。側面・フタ上面・底面に同じ幅で現れる。

    Base 用と Lid 用で上下に分けて2回呼ぶので、高さの範囲を引数で受ける。

    2枚目をわずかに大きく・高くしているのは、上面／底面の中央で
    天面同士が同一平面になって Z ファイティングするのを避けるため。
    2枚目は呼び出し側で Z 軸まわりに90度回してから使う。
    """
    height = z_hi - z_lo
    z = (z_hi + z_lo) / 2.0
    skew = RIBBON_SKEW
    return [
        paint(box("RibbonX" + suffix, (RIBBON_OUT * 2.0, RIBBON_W, height),
                  loc=(0, 0, z)), "Ribbon"),
        paint(box("RibbonY" + suffix, ((RIBBON_OUT + skew) * 2.0, RIBBON_W, height + skew * 2.0),
                  loc=(0, 0, z)), "Ribbon"),
    ]


def build_bow():
    """蝶結び。結び目の角丸キューブ＋左右の輪2枚だけ。"""
    parts = [paint(beveled_box("Knot", (0.28, 0.24, 0.16),
                               loc=(0, 0, RIBBON_TOP + 0.05), bevel=0.05), "Ribbon")]
    for side in (1.0, -1.0):
        loop = torus("BowLoop", BOW_R, BOW_TUBE)
        # 寝たドーナツを立てつつ、輪を横長の楕円に潰す（リボンらしい平たさ）
        bake(loop, scale=(1.3, 0.6, 1.0), rot=(math.pi / 2.0, 0, 0))
        # 外側へ倒して結び目の左右へ置く
        bake(loop, rot=(0.0, -0.5 * side, 0.0), loc=(BOW_R * 1.2 * side, 0.0, BOW_Z))
        parts.append(paint(loop, "Ribbon"))
    return parts


def build_ribbon_cross(z_lo, z_hi, suffix):
    """十字のリボン。2枚目を Z 軸まわりに90度回して交差させる。"""
    ribbon_x, ribbon_y = build_ribbon(z_lo, z_hi, suffix)
    bake(ribbon_y, rot=(0.0, 0.0, math.pi / 2.0))
    return [ribbon_x, ribbon_y]


def build_base():
    """下箱＋リボン下部を1メッシュ（Base）へ結合する。"""
    base = cleanup(join_into(build_box_part(), build_ribbon_cross(RIBBON_BOT, SEAM, "Lo")))
    base.name = base.data.name = "Base"
    return base


def build_lid():
    """フタ＋リボン上部＋蝶結びを1メッシュ（Lid）へ結合する。

    原点をフタの中心に置くので、Godot 側で Lid ノードを回すと
    その場で傾く（箱の中心を軸にした公転にならない）。開封演出のため。
    """
    parts = build_ribbon_cross(SEAM - SEAM_OVERLAP, RIBBON_TOP, "Hi") + build_bow()
    lid = cleanup(join_into(build_lid_part(), parts))
    lid.name = lid.data.name = "Lid"
    return set_origin(lid, (0.0, 0.0, LID_Z))


def build_burst_ring():
    """開いた瞬間に足元へ広がる光の輪。厚みゼロの水平な円環1枚。

    Godot 側は加算合成の unshaded・cull_disabled で描くので、
    裏表のある板1枚で足りる（体積を持たせる必要がない）。

    原点を輪自身の高さへ移すのは、Godot 側で scale した時に
    高さを保ったまま水平に広がるようにするため（set_origin の説明を参照）。
    set_origin は原点を動かすだけで輪そのものは動かないので、
    高さは lathe のプロファイル側でも BURST_Z を指定してある。
    """
    ring = lathe("Burst", [(BURST_Z, BURST_R), (BURST_Z, BURST_R + BURST_W)], 32)
    ring.data.name = "Burst"
    paint(ring, "Spark")
    return set_origin(ring, (0.0, 0.0, BURST_Z))


def build_confetti():
    """外へ舞う紙吹雪。細長い薄板を散らして1メッシュへ結合する（build_manhole の Shards と同じ作り）。

    方位角を黄金角(2.4rad)で振るのは見た目の都合ではなく必須。
    beacon.gdshader は 1 メッシュに結合された飾りを揺らすのに
    頂点の方位角 atan(x, z) を位相として使うので、方位角が重なると
    紙片が同じ位相で揃って動いてしまう。

    傾きは i から決まる式で与える（乱数を使わない）。ビルドを
    何度回しても同じ glb になるようにするため。

    原点は箱の中心のまま。Godot 側で scale すると中心から外へ広がる。
    """
    parts = []
    for i in range(CONFETTI_COUNT):
        a = 2.4 * i
        radius = 0.55 + 0.30 * (i % 4)
        z = 0.10 + 0.13 * ((i * 5) % 7)
        piece = box("Confetti%d" % i, (CONFETTI_L, CONFETTI_W, CONFETTI_T))
        # 紙片ごとに向きを変えてから、方位角 a の位置へ置く
        bake(piece, rot=(a * 1.7, a * 1.1 + 0.6, a))
        parts.append(bake(piece, loc=(math.cos(a) * radius, math.sin(a) * radius, z)))
    confetti = paint(cleanup(join_into(parts[0], parts[1:])), "Spark")
    confetti.name = confetti.data.name = "Confetti"
    return confetti


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    build_base()
    build_lid()
    build_burst_ring()
    build_confetti()
    for obj in bpy.data.objects:
        print("object :", obj.name, "verts", len(obj.data.vertices),
              "loc", tuple(round(v, 3) for v in obj.location))


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH, export_format='GLB', export_yup=True, export_apply=True,
        export_animations=False, export_skins=False,
        export_cameras=False, export_lights=False,
        export_materials='EXPORT', export_texcoords=False,
        use_visible=False, use_selection=False)
    print("saved  :", BLEND_PATH)
    print("export :", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")


def render_previews(out_dir):
    """形と配色の確認用プレビュー。バックグラウンドでも確実に動く Workbench で描く。"""
    import mathutils
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.render_aa = '8'
    scene.render.resolution_x, scene.render.resolution_y = 640, 640
    scene.render.film_transparent = False

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    cam.data.lens = 50
    scene.camera = cam

    burst = bpy.data.objects["Burst"]
    confetti = bpy.data.objects["Confetti"]

    def shoot(name, deg, target_z, dist):
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "item_box_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)

    # 通常の3ショットは箱そのものの形を見るためのものなので、
    # ふだんは出ていない開封エフェクトを外しておく
    burst.hide_render = confetti.hide_render = True
    # (名前, カメラ角度, 注視点の高さ, 距離)
    for name, deg, target_z, dist in [
        ("three_quarter", (68, 0, -35), 0.0, 4.2),
        ("front", (85, 0, 0), 0.0, 3.8),
        ("top", (10, 0, 0), 0.0, 3.8),
    ]:
        shoot(name, deg, target_z, dist)

    # 開封の瞬間。Godot 側の Tween が作る姿勢をだいたい再現して、
    # 光の輪と紙吹雪が箱に埋もれていないかを確かめる
    burst.hide_render = confetti.hide_render = False
    burst.scale = (2.2, 2.2, 1.0)
    confetti.scale = (1.9, 1.9, 1.9)
    confetti.location = (0.0, 0.0, 1.0)
    lid = bpy.data.objects["Lid"]
    lid.location = (lid.location.x, lid.location.y, lid.location.z + 1.5)
    lid.rotation_euler = (0.6, 0.9, 3.4)
    shoot("burst", (72, 0, -35), 0.3, 5.6)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        out_dir = argv[argv.index("--render") + 1]
        if not os.path.isabs(out_dir):
            out_dir = os.path.join(PROJECT, out_dir)
        render_previews(out_dir)


main()
