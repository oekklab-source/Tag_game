"""ジャンプ台（バネ式打ち上げ台）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_spring_pad.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/spring_pad.blend   編集元（.gdignore で Godot のインポート対象外）
    assets/gimmicks/spring_pad.glb   Godot が読むモデル

地面に埋まらず、地面（z=0）の上に台座が堂々と乗る構造にする。
台座の上にバネの支点（Spring ノード）を置き、踏んだときの伸縮アニメーションが
台座の上で自然に伸び縮みするようにする。
"""

import math
import os
import sys

import bmesh
import bpy

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "spring_pad.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "spring_pad.glb")

# ---- 配色（Blender は Z-up。単位はメートル。地面は z=0）----
COLORS = {
    "BaseDark": (0.20, 0.20, 0.24),   # 台座。どの床色に対しても明度差で沈む
    "Coil": (0.68, 0.70, 0.74),       # バネのコイル。金属寄りのシルバー
    "PadOrange": (0.82, 0.32, 0.06),  # 着地面。WorldData.ZONE_ACCENTS[6] より暗く濃い橙
    "PadRim": (0.32, 0.11, 0.03),     # 着地面の縁。さらに暗くして輪郭を締める
}
EMISSION = {"BaseDark": 0.0, "Coil": 0.0, "PadOrange": 0.2, "PadRim": 0.0}
METALLIC = {"BaseDark": 0.0, "Coil": 0.6, "PadOrange": 0.0, "PadRim": 0.0}

BASE_HEIGHT = 0.22  # 台座の上面の高さ（地面 z=0 から上）


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
    bsdf.inputs["Roughness"].default_value = 0.4
    bsdf.inputs["Metallic"].default_value = METALLIC[name]
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
    """(高さ, 半径) の並びを Z 軸まわりの回転体にする。"""
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


def torus(name, z, major, minor, segments=28, rings=12):
    """Z 軸まわりのトーラス。"""
    profile = [(z + math.sin(2.0 * math.pi * i / rings) * minor,
                major + math.cos(2.0 * math.pi * i / rings) * minor)
               for i in range(rings)]
    profile.append(profile[0])
    return lathe(name, profile, segments)


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
    """重複頂点と法線を整理する。"""
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
    """地面の上に堂々と載る厚みのある台座。底面を z=0.0 にして地面の上に置く。"""
    profile = [
        (0.00, 0.0),
        (0.00, 1.55),
        (0.04, 1.60),
        (0.16, 1.60),
        (BASE_HEIGHT, 1.48),
        (BASE_HEIGHT, 0.0),
    ]
    return paint(cleanup(lathe("Base", profile, 28, smooth=False)), "BaseDark")


def build_coils(root):
    """バネのコイル。ローカル z=0（台座上面）から立ち上げる。"""
    rings = [
        torus("Coil1", 0.14, 1.05, 0.14),
        torus("Coil2", 0.32, 0.95, 0.13),
        torus("Coil3", 0.50, 0.85, 0.12),
    ]
    coil = paint(cleanup(join_into(rings[0], rings[1:])), "Coil")
    coil.parent = root
    return coil


def build_pad(root):
    """着地面。ドーム状の丸みを持ち、縁に暗い橙のリムを足す。"""
    profile = [
        (0.58, 0.0),
        (0.58, 1.30),
        (0.64, 1.35),
        (0.76, 1.18),
        (0.83, 0.55),
        (0.86, 0.0),
    ]
    pad = paint(cleanup(lathe("Pad", profile, 28, smooth=True)), "PadOrange")
    rim = paint(torus("PadRim", 0.60, 1.32, 0.055), "PadRim")
    pad = paint(cleanup(join_into(pad, [rim])), "PadOrange")
    pad.parent = root
    return pad


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    root = bpy.data.objects.new("SpringPad", None)
    bpy.context.collection.objects.link(root)

    base = build_base()
    base.parent = root

    # Coil/Pad をまとめる空オブジェクト。台座上面（z=BASE_HEIGHT）に置く
    spring = bpy.data.objects.new("Spring", None)
    spring.location = (0.0, 0.0, BASE_HEIGHT)
    bpy.context.collection.objects.link(spring)
    spring.parent = root
    build_coils(spring)
    build_pad(spring)

    for obj in bpy.data.objects:
        verts = len(obj.data.vertices) if obj.data else 0
        print("object :", obj.name, "verts", verts, "loc", tuple(round(v, 3) for v in obj.location))


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
    """形の確認用プレビュー。"""
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
    shots = [
        ("three_quarter", (70, 0, -40), 0.5, 4.2),
        ("side", (90, 0, 90), 0.5, 4.0),
        ("top", (30, 0, 0), 0.5, 4.0),
    ]
    for name, deg, target_z, dist in shots:
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "spring_pad_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1])


main()
