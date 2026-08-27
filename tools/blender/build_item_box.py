"""？ブロック（アイテムボックス）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_item_box.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/item_box.blend      編集元（.gdignore で Godot のインポート対象外）
    assets/props/item_box.glb         Godot が読むモデル

見た目は「リボンを掛けたプレゼント箱」。下箱・フタ・十字のリボン・
上面の蝶結びだけで作り、色も包装紙／リボンの2色に絞る。中身が何かは
見せない（「？」も舞う結晶も置かない）。

アニメーションは書き出さない。回転演出は manhole と同じく Godot 側の
_process() で毎フレーム rotate_y する（AnimationPlayer を増やさない）。
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

# ---- 配色 ----
# 包装紙とリボンの2色だけで構成する。色数を増やすより、
# 「リボンの掛かった箱」という形の分かりやすさを優先する
COLORS = {
    "Wrap": (0.90, 0.20, 0.26),
    "Lid": (0.98, 0.32, 0.36),   # 同系の明るい色。フタの段差を光ではなく色で見せる
    "Ribbon": (0.99, 0.93, 0.80),
}
# 暗い場所でも沈まないよう、全体をわずかに発光させる
EMISSION = {
    "Wrap": 0.10, "Lid": 0.12, "Ribbon": 0.20,
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
    bsdf.inputs["Roughness"].default_value = 0.35
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

def build_base():
    """下箱。包装紙の色ひとつで塗る。"""
    return paint(beveled_box("Base", (BODY_W, BODY_W, BASE_H), loc=(0, 0, BASE_Z)), "Wrap")


def build_lid():
    """一回り大きく被せるフタ。ここが乗ることで「箱」ではなく「贈り物」に見える。"""
    return paint(beveled_box("Lid", (LID_W, LID_W, LID_H), loc=(0, 0, LID_Z), bevel=0.04), "Lid")


def build_ribbon():
    """箱を十字に貫く2枚の帯。側面・フタ上面・底面に同じ幅で現れる。

    2枚目をわずかに大きく・高くしているのは、上面／底面の中央で
    天面同士が同一平面になって Z ファイティングするのを避けるため。
    2枚目は呼び出し側で Z 軸まわりに90度回してから使う。
    """
    height = RIBBON_TOP - RIBBON_BOT
    z = (RIBBON_TOP + RIBBON_BOT) / 2.0
    skew = RIBBON_SKEW
    return [
        paint(box("RibbonX", (RIBBON_OUT * 2.0, RIBBON_W, height), loc=(0, 0, z)), "Ribbon"),
        paint(box("RibbonY", ((RIBBON_OUT + skew) * 2.0, RIBBON_W, height + skew * 2.0),
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


def build_body():
    """下箱・フタ・リボン・蝶結びを1メッシュ（Body）へ結合する。

    取得後の「使用済み」表示は question_block.gd が Body へ material_override を
    掛けて一括で暗くするので、色の違うパーツもすべてここに含める。
    """
    ribbon_x, ribbon_y = build_ribbon()
    bake(ribbon_y, rot=(0.0, 0.0, math.pi / 2.0))
    parts = [ribbon_x, ribbon_y] + build_bow() + [build_lid()]
    body = cleanup(join_into(build_base(), parts))
    body.name = body.data.name = "Body"
    return body


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    build_body()
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
    # (名前, カメラ角度, 注視点の高さ, 距離)
    shots = [
        ("three_quarter", (68, 0, -35), 0.0, 4.2),
        ("front", (85, 0, 0), 0.0, 3.8),
        ("top", (10, 0, 0), 0.0, 3.8),
    ]
    for name, deg, target_z, dist in shots:
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "item_box_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1])


main()
