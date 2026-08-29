"""ジャンプ台（バネ式打ち上げ台）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_spring_pad.py

出力:
    tools/blender/spring_pad.blend   編集元（.gdignore で Godot のインポート対象外）
    assets/gimmicks/spring_pad.glb   Godot が読むモデル

旧モデルは Godot 側で組んだ CylinderMesh + TorusMesh 一色（鮮やかな黄色）で、
SPRING VALLEY ゾーンの床色（world_data.gd の ZONE_COLORS[6]、ほぼ同じ黄色）
に同化していた。SPRING_PADS は床色がバラバラな9ゾーンに置かれるため、
一色を塗り替えるだけでは別のゾーンで再び同化しかねない。

build_manhole.py と同じ考え方（本体は周囲のパステルに対して締まる
「暗色ニュートラル」、装飾だけを鮮やかなアクセント色にする）を踏襲し、
どの床色に対しても明度差で輪郭が立つようにする。着地面の橙は
WorldData.ZONE_ACCENTS[6]（「構造物はゾーンのアクセント色」という既存の
配色ルール）をベースに、薄く見えないよう明度・彩度を落として濃くしてある。

アニメーションは書き出さない。踏んだときの伸縮演出は spring_pad.gd の
Tween が引き続き担当する（build_manhole.py のフタ開閉と同じ方針）。
そのため Base とバネ本体（Coil+Pad）は親を分けて書き出す。バネ本体だけを
まとめる "Spring" 空オブジェクトを z=0（台座の上面）に置くのが要点で、
Godot 側は Spring の scale.y を伸ばすだけで「台座は動かず、バネだけが
びよーんと伸びる」動きになる（コイルの根元がちょうど z=0 にあるため、
Y方向のスケールはそこを支点に上だけが伸びる）。
"""

import math
import os

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


# =====================================================================
# 汎用ヘルパ（build_manhole.py と同じ形）
# =====================================================================

def make_mat(name):
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


def torus(name, z, major, minor, segments=28, rings=12):
    """Z 軸まわりのトーラス。断面の円を閉じた輪として渡す。"""
    profile = [(z + math.sin(2.0 * math.pi * i / rings) * minor,
                major + math.cos(2.0 * math.pi * i / rings) * minor)
               for i in range(rings)]
    profile.append(profile[0])
    return lathe(name, profile, segments)


def join_into(target, others):
    bpy.ops.object.select_all(action="DESELECT")
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
    """地面に薄く埋まる台座。中心から半径を出し縁を丸めて上面を閉じた円盤にする。"""
    profile = [
        (-0.30, 0.0),
        (-0.30, 1.55),
        (-0.24, 1.60),
        (0.00, 1.60),
        (0.05, 1.45),
        (0.05, 0.0),
    ]
    return paint(cleanup(lathe("Base", profile, 28, smooth=False)), "BaseDark")


def build_coils(root):
    """バネのコイル。トーラスを3段重ねて上にすぼめ、一目でバネと分かる形にする。

    旧モデルは平たいリング1枚だけで「バネ」に見えなかった反省を踏まえ、
    段を追うごとに半径を細くして先細りのコイルらしいシルエットにする。
    根元（1段目）が z=0 に来るようにし、root の原点を伸縮の支点にする。
    """
    rings = [
        torus("Coil1", 0.14, 1.05, 0.14),
        torus("Coil2", 0.32, 0.95, 0.13),
        torus("Coil3", 0.50, 0.85, 0.12),
    ]
    coil = paint(cleanup(join_into(rings[0], rings[1:])), "Coil")
    coil.parent = root
    return coil


def build_pad(root):
    """着地面。わずかにドーム状にして「弾む場所」の丸みを出す。縁に暗い橙のリムを足す。"""
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

    # Coil/Pad をまとめる空オブジェクト。z=0（台座の上面）に置くことで、
    # Godot 側がこのノードの scale.y を動かすだけで「根元は動かず上だけ伸びる」
    # バネの動きになる。
    spring = bpy.data.objects.new("Spring", None)
    bpy.context.collection.objects.link(spring)
    spring.parent = root
    build_coils(spring)
    build_pad(spring)

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


def main():
    build()
    export()


main()
