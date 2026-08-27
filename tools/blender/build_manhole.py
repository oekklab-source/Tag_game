"""ワープ地点のマンホールを一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_manhole.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/manhole.blend       編集元（.gdignore で Godot のインポート対象外）
    assets/props/manhole.glb          Godot が読むモデル

土管を廃止した代わりの入口。フタは地面と面一なので静的コリジョンを持たず、
ナビメッシュに穴を空けない（土管は半径1.5mの穴を空けていた）。
その代わり遠くから見つけられなくなるので、天へ伸びる光柱・回転リング・
舞う結晶を同じモデルに含めて「ここがワープ地点だ」と分かるようにする。

アニメーションは書き出さない。フタの開閉は Godot 側の Tween でやる
（spring_pad / bumper と同じ手法に揃え、AnimationPlayer を増やさない）。
そのため Lid だけは原点をヒンジ（枠の内縁）に置いてあり、Godot 側は
rotation.x を回すだけで開く。
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
FRAME_R_OUT, FRAME_R_IN = 1.30, 1.12
FRAME_TOP, FRAME_BOTTOM = 0.03, -0.40   # 上面をわずかに地面より上げて Z ファイティングを避ける
LID_R, LID_TOP, LID_BOTTOM = 1.08, 0.03, -0.11
HINGE_Y = FRAME_R_IN                    # フタの回転軸。Godot では z = -1.12 に来る
SHAFT_TOP, SHAFT_BOTTOM = -0.05, -0.95
BEACON_H = 14.0                         # SKY STEPS(6m)+柵(2.5m) より高く、雲(40m〜) には届かない
SHARD_COUNT = 12

# ---- 配色 ----
COLORS = {
    "MetalDark": (0.34, 0.36, 0.44),    # フタと枠。周囲のパステルに対して締まる暗色
    "HoleDark": (0.03, 0.05, 0.09),     # 縦穴
    "HoloGold": (0.98, 0.72, 0.16),     # 紋章・回転リング
    "HoloCyan": (0.62, 0.92, 1.00),     # 光柱・結晶
}
# 金は「albedo * 光 + emission」の和が glow_hdr_threshold(1.0) を超えないところまで
# 抑える。超えるとリングも紋章も白く飛んで金色に見えなくなる（近景で実測）。
# シアンの光柱と結晶は Godot 側で beacon.gdshader に差し替わるのでここの値は効かない
EMISSION = {"MetalDark": 0.0, "HoleDark": 0.0, "HoloGold": 0.25, "HoloCyan": 2.6}


# =====================================================================
# 汎用ヘルパ（build_fallguy.py と同じ形）
# =====================================================================

def make_mat(name):
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


def box(name, size, loc=(0, 0, 0), rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return bake(obj, loc=loc, rot=rot, scale=size)


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


def torus(name, z, major, minor, segments=32, rings=12):
    """Z 軸まわりのトーラス。断面の円を閉じた輪として渡す。"""
    profile = [(z + math.sin(2.0 * math.pi * i / rings) * minor,
                major + math.cos(2.0 * math.pi * i / rings) * minor)
               for i in range(rings)]
    profile.append(profile[0])
    return lathe(name, profile, segments)


# =====================================================================
# パーツ
# =====================================================================

def build_frame():
    """地面に埋まったリング枠。断面を閉じた輪にして中実の輪にする。"""
    profile = [
        (FRAME_BOTTOM, FRAME_R_OUT),
        (FRAME_TOP - 0.04, FRAME_R_OUT),
        (FRAME_TOP, FRAME_R_OUT - 0.05),   # 外側の面取り
        (FRAME_TOP, FRAME_R_IN + 0.03),
        (FRAME_TOP - 0.05, FRAME_R_IN),    # 内側はフタを受ける段
        (FRAME_BOTTOM, FRAME_R_IN),
    ]
    profile.append(profile[0])
    return paint(cleanup(lathe("Frame", profile, 32, smooth=False)), "MetalDark")


def build_lid():
    """フタ。原点をヒンジ（枠の内縁 y=+HINGE_Y）に置くのが要点。

    Godot 側は Blender +Y が -Z に来るので、ヒンジは z=-1.12 に立ち、
    rotation.x を負に回すと反対側の縁が持ち上がる。
    """
    profile = [
        (LID_BOTTOM, 0.0),
        (LID_BOTTOM, LID_R - 0.04),
        (LID_BOTTOM + 0.04, LID_R),
        (LID_TOP - 0.03, LID_R),
        (LID_TOP, LID_R - 0.04),
        (LID_TOP, 0.0),
    ]
    lid = paint(cleanup(lathe("Lid", profile, 32, smooth=False)), "MetalDark")

    # 放射リブ。マンホールらしさはこの模様で出る
    ribs = []
    for i in range(12):
        a = 2.0 * math.pi * i / 12
        ribs.append(paint(box("Rib", (0.09, 0.62, 0.05),
                              loc=(math.cos(a) * 0.68, math.sin(a) * 0.68, LID_TOP),
                              rot=(0.0, 0.0, a + math.pi * 0.5)), "MetalDark"))
    lid = join_into(lid, ribs)

    # 中央の紋章。ここだけ金にして「ただのフタではない」と分からせる
    emblem = paint(torus("Emblem", LID_TOP + 0.01, 0.40, 0.045, 24, 8), "HoloGold")
    spikes = []
    for i in range(6):
        a = 2.0 * math.pi * i / 6
        spikes.append(paint(box("Spike", (0.07, 0.30, 0.06),
                                loc=(math.cos(a) * 0.20, math.sin(a) * 0.20, LID_TOP + 0.01),
                                rot=(0.0, 0.0, a + math.pi * 0.5)), "HoloGold"))
    lid = join_into(lid, [emblem] + spikes)
    cleanup(lid)

    # 頂点をヒンジ基準にずらしてから、オブジェクト位置でヒンジへ戻す。
    # こうするとオブジェクトの原点がヒンジそのものになる
    bake(lid, loc=(0.0, -HINGE_Y, 0.0))
    lid.location = (0.0, HINGE_Y, 0.0)
    return lid


def build_shaft():
    """フタの下の縦穴。下すぼまりにして深さを感じさせる。"""
    profile = [
        (SHAFT_BOTTOM, 0.0),
        (SHAFT_BOTTOM, 0.34),
        (SHAFT_TOP, FRAME_R_IN - 0.02),
        (SHAFT_TOP, 0.0),
    ]
    return paint(cleanup(lathe("Shaft", profile, 24, smooth=False)), "HoleDark")


def build_halo():
    """足元に浮かぶ二重の回転リング。Godot 側で rotate_y する。"""
    outer = torus("Halo", 0.35, 1.70, 0.055)
    inner = torus("HaloInner", 0.62, 1.50, 0.045)
    return paint(cleanup(join_into(outer, [inner])), "HoloGold")


def build_beacon():
    """天へ伸びる光柱。上下のフタを付けない開いた筒にして、加算合成で溶かす。

    二重にしてあるのは、外殻だけだと真横から見た時に輪郭が細く見えるため。
    根元を z=0.75 から始めて細くしてあるのは、太い筒がフタの意匠を隠してしまうため。
    """
    outer = lathe("Beacon", [(0.75, 0.52), (BEACON_H, 0.30)], 24)
    inner = lathe("BeaconCore", [(0.50, 0.18), (BEACON_H + 1.6, 0.05)], 16)
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
        radius = 1.35 + 0.16 * (i % 5)
        s = 0.20 + 0.05 * ((i * 7) % 3)
        oct_profile = [(-s * 1.5, 0.0), (0.0, s), (s * 1.5, 0.0)]
        shard = lathe("Shard", oct_profile, 4, smooth=False)
        parts.append(bake(shard,
                          loc=(math.cos(a) * radius, math.sin(a) * radius, 1.0 + 0.85 * i),
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
    build_frame()
    build_lid()
    build_shaft()
    build_halo()
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
    """形の確認用プレビュー。バックグラウンドでも確実に動く Workbench で描く。

    光柱が 14m あるので、足元の造作を見る近景と全体を見る遠景の両方を出す。
    """
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
    # (名前, カメラ角度, 注視点の高さ, 距離)
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
