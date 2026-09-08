"""ワープ地点の光の柱（ビーコン・舞う結晶）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_manhole.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/manhole.blend       編集元（.gdignore で Godot のインポート対象外）
    assets/props/manhole.glb          Godot が読むモデル

マンホール（枠・フタ・穴）や足元のリングを無くし、天へ伸びる光柱・舞う結晶のみで構成する。
フタが無く地面から光が立ち昇るため、ナビメッシュに穴を空けず、遠くからでも目立つ。
"""

import math
import os
import sys

import bmesh
import bpy

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "manhole.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "props", "manhole.glb")

# ---- 寸法（Blender は Z-up。単位はメートル。地面は z=0）----
BEACON_H = 14.0                         # SKY STEPS(6m)+柵(2.5m) より高く、雲(40m〜) には届かない
SHARD_COUNT = 12

# ---- 配色 ----
COLORS = {
    "HoloCyan": (0.62, 0.92, 1.00),     # 光柱・結晶
}
EMISSION = {"HoloCyan": 2.6}


# =====================================================================
# 汎用ヘルパ
# =====================================================================

def make_mat(name):
    """マテリアルを作成または取得して設定する。"""
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    rgb = COLORS[name]
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.42
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = EMISSION[name]
    mat.diffuse_color = (*rgb, 1.0)
    return mat


def paint(obj, name):
    """オブジェクトにマテリアルを適用する。"""
    obj.data.materials.clear()
    obj.data.materials.append(make_mat(name))
    return obj


def lathe(name, profile, segments=24, smooth=True):
    """(高さ, 半径) の並びを Z 軸まわりの回転体にする。半径0の点は極として1頂点に潰す。

    profile の先頭と末尾を同じ点にすると閉じた輪（トーラス・角断面のリング）になる。
    先頭と末尾が半径0なら閉じた立体になる。どちらでもなければ両端の開いた筒。
    """
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


def join_into(target, others):
    """複数オブジェクトをターゲットに結合する。"""
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

def build_beacon():
    """天へ伸びる光柱。上下のフタを付けない開いた筒にして、加算合成で溶かす。

    地面（z=0.0）から立ち上がる。二重にしてあるのは、外殻だけだと真横から見た時に輪郭が細く見えるため。
    """
    outer = lathe("Beacon", [(0.0, 0.65), (BEACON_H, 0.30)], 24)
    inner = lathe("BeaconCore", [(0.0, 0.25), (BEACON_H + 1.6, 0.06)], 16)
    return paint(join_into(outer, [inner]), "HoloCyan")


def build_shards():
    """光柱のまわりを舞う八面体の結晶。らせんに並べて 1 メッシュへ結合する。

    Godot 側は MultiMesh ではないのでインスタンスごとの位相を渡せない。
    代わりにシェーダが頂点の方位角を位相に使うので、
    結晶どうしの方位角が重ならないよう黄金角(2.4rad)で回してある。
    """
    parts = []
    for i in range(SHARD_COUNT):
        a = 2.4 * i
        radius = 1.10 + 0.15 * (i % 5)
        s = 0.18 + 0.04 * ((i * 7) % 3)
        oct_profile = [(-s * 1.5, 0.0), (0.0, s), (s * 1.5, 0.0)]
        shard = lathe("Shard", oct_profile, 4, smooth=False)
        parts.append(bake(shard,
                          loc=(math.cos(a) * radius, math.sin(a) * radius, 0.6 + 0.85 * i),
                          rot=(0.0, 0.0, a)))
    shards = paint(join_into(parts[0], parts[1:]), "HoloCyan")
    shards.name = shards.data.name = "Shards"
    return shards


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    build_beacon()
    build_shards()
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
    """形の確認用プレビュー。"""
    import mathutils
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.render_aa = '8'
    scene.render.resolution_x, scene.render.resolution_y = 620, 720
    scene.render.film_transparent = False

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    cam.data.lens = 50
    scene.camera = cam
    shots = [
        ("near_three", (74, 0, -40), 0.5, 5.0),
        ("near_side", (90, 0, 90), 0.4, 4.6),
        ("near_top", (28, 0, 0), 0.2, 4.2),
        ("full", (84, 0, -30), 7.0, 26.0),
    ]
    for name, deg, target_z, dist in shots:
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "manhole_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1])


main()
