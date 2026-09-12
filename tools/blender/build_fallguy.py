"""Fall Guys 風・恐竜きぐるみキャラを一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_fallguy.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/fallguy.blend       編集元（.gdignore で Godot のインポート対象外）
    assets/character/fallguy.glb      Godot が読むモデル

体色（きぐるみのスーツ部分）だけを Body オブジェクトに集約してあり、Godot 側は
material_override 一発で役割色（Runner=緑 / Hunter=赤）に差し替えられる。
ピンクの肌・白い顔・トゲ・爪は Costume / Face 側に分けて固定色のまま残す。
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from character_common import *  # noqa: E402,F403  骨格・リグ・アニメ・書き出し

BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "fallguy.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "character", "fallguy.glb")

# ---- パステル配色（参考画像より）----
COLORS = {
    "Body": (0.55, 0.88, 0.70),        # きぐるみのミント。Godot 側で役割色に差し替わる
    "Skin": (0.97, 0.72, 0.72),        # 袖から出た腕と顔まわりのピンク
    "FaceWhite": (0.99, 0.98, 0.97),
    "Pupil": (0.11, 0.09, 0.13),
    "SpikeYellow": (0.99, 0.87, 0.42),
    "SpikePurple": (0.78, 0.65, 0.95),
    "SpikeBlue": (0.60, 0.80, 0.96),
    "Claw": (0.99, 0.99, 0.98),
}
# 体色は Godot 側で弱く自己発光させるので、他も同じ強さにして相対的に沈まないようにする
EMISSION = {"Pupil": 0.0, "Body": 0.0}
EMISSION_DEFAULT = 0.35
set_palette(COLORS, EMISSION, EMISSION_DEFAULT)


# =====================================================================
# メッシュ
# =====================================================================

LEG = [(0.040, 0.000), (0.060, 0.080), (0.100, 0.112), (0.170, 0.126),
       (0.280, 0.128), (0.400, 0.130), (0.520, 0.134), (0.610, 0.138),
       (0.660, 0.110), (0.680, 0.000)]
# 袖から先のミトン（手）。手首(WRIST_Z)より先だけがスーツ色になる
MITT = cap(-0.360, 0.125) + [(-0.325, 0.121), (-0.290, 0.112), (-0.262, 0.098), (-0.245, 0.000)]
# 袖の中のピンクの腕。手首より上を覆う
SKIN_ARM = [(-0.295, 0.000), (-0.280, 0.052), (-0.262, 0.078), (-0.240, 0.088),
            (-0.100, 0.086), (0.000, 0.090), (0.070, 0.088), (0.105, 0.068), (0.130, 0.000)]
TAIL = [(0.000, 0.000), (0.020, 0.092), (0.080, 0.132), (0.170, 0.122),
        (0.280, 0.096), (0.370, 0.062), (0.440, 0.028), (0.470, 0.000)]
TAIL_BASE = (0.0, body_radius(0.80) - 0.020, 0.80)
TAIL_ROT = (math.radians(-112.0), 0.0, 0.0)

# 背びれ: 頭頂から背中・しっぽへ。(高さ, 色) で並べる
SPIKES = [(1.600, "SpikeYellow"), (1.520, "SpikePurple"), (1.430, "SpikeBlue"),
          (1.320, "SpikeYellow"), (1.190, "SpikePurple"), (1.060, "SpikeBlue"),
          (0.930, "SpikeYellow"), (0.810, "SpikePurple")]
BELLY = [(0.960, "SpikeYellow"), (0.830, "SpikeBlue"), (0.700, "SpikePurple")]


def build_body():
    """スーツ色にまとまるパーツ: 豆型ボディ・フード・脚・ブーツ・ミトン。
    しっぽとフードはリグを組んだ後に別途ウェイトを付けて合流させる。"""
    body = lathe("Body", BODY_PROFILE, segments=24)
    parts = []
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        loc, rot = arm_transform(sx)
        parts.append(bake(lathe("Mitt" + side, MITT, 16), loc=loc, rot=rot))
        parts.append(bake(lathe("Leg" + side, LEG, 16),
                          loc=(HIP_X * sx, 0.0, 0.0), rot=(0.0, -0.05 * sx, 0.0)))
        parts.append(ball("Boot" + side, (HIP_X * sx, -0.062, 0.106), (0.150, 0.215, 0.106)))
    join_into(body, parts)
    body.data.materials.append(make_mat("Body"))
    for poly in body.data.polygons:
        poly.material_index = 0
    return body


def build_hood():
    """頭をすっぽり覆う恐竜フード。正面はブーリアンで丸くくり抜く。"""
    profile = [(z, r) for z, r in BODY_PROFILE if z >= HOOD_Z0]
    profile.insert(0, (HOOD_Z0, body_radius(HOOD_Z0)))
    hood = lathe("Hood", offset_profile(profile, HOOD_OUT), segments=24)
    solid = hood.modifiers.new("Solidify", 'SOLIDIFY')
    solid.thickness, solid.offset = HOOD_THICK, -1.0

    bpy.ops.mesh.primitive_cylinder_add(radius=FACE_HOLE_R, depth=1.2, vertices=28,
                                        location=(0.0, -0.5, FACE_Z),
                                        rotation=(math.radians(90), 0.0, 0.0))
    cutter = bpy.context.object
    hole = hood.modifiers.new("Hole", 'BOOLEAN')
    hole.operation, hole.object, hole.solver = 'DIFFERENCE', cutter, 'EXACT'
    apply_mods(hood)
    bpy.data.objects.remove(cutter, do_unlink=True)
    cleanup(hood)

    # 耳はスーツと同じ色なので、役割色の差し替えが効くようフード（=Body 側）に含める
    ears = []
    for sx in (1.0, -1.0):
        pos, normal, frame = surface_frame(1.505, 1.00 * sx)
        ear = cone("Ear" + ("L" if sx > 0 else "R"), 0.062, 0.100, segments=10)
        ears.append(bake(ear, loc=tuple(pos + normal * HOOD_OUT), rot=frame))
    join_into(hood, ears)
    for poly in hood.data.polygons:
        poly.use_smooth = True
    return hood


def build_tail():
    tail = bake(lathe("Tail", TAIL, 16), loc=TAIL_BASE, rot=TAIL_ROT)
    spikes = []
    # しっぽローカルの -Y が、回転後は「しっぽの背中側」になる
    for i, (along, out, size) in enumerate(((0.100, 0.112, 0.050),
                                            (0.220, 0.098, 0.043),
                                            (0.330, 0.070, 0.034))):
        spike = cone("TailSpike%d" % i, size, size * 1.7, segments=8)
        bake(spike, loc=(0.0, -out, along), rot=(math.radians(90.0), 0.0, 0.0))
        spikes.append(bake(spike, loc=TAIL_BASE, rot=TAIL_ROT))
    return tail, spikes


def build_face():
    """フードの穴から覗く白い顔。小さな黒目・キラリ・にっこり口。

    顔は平たい円盤ではなく「頭の表面をわずかに外へオフセットした帯」にしてある。
    穴のふちは頭の丸みに沿って前後に大きくうねるので、平たい円盤だと下側で
    ボディが手前に出てしまう。帯は生地の内側に隠れ、穴の部分だけが見える。"""
    white, pupil = make_mat("FaceWhite"), make_mat("Pupil")
    band = [(z, r) for z, r in BODY_PROFILE if 1.05 <= z <= 1.55]
    disc = lathe("FaceDisc", offset_profile(band, 0.014), segments=28)
    solid = disc.modifiers.new("Solidify", 'SOLIDIFY')
    solid.thickness, solid.offset = 0.008, -1.0
    apply_mods(disc)
    disc.data.materials.append(white)
    def on_face(azimuth, z, out):
        """白い帯の上の点。帯は頭の丸みに沿うので、目や口も同じ曲面に乗せる。"""
        r = body_radius(z) + 0.014 + out
        return (r * math.sin(azimuth), -r * math.cos(azimuth), z), (0.0, 0.0, azimuth)

    parts = []
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        pos, rot = on_face(0.245 * sx, FACE_Z + 0.022, -0.006)
        eye = ball("Eye" + side, pos, (0.036, 0.026, 0.049), rot=rot)
        eye.data.materials.append(pupil)
        pos, rot = on_face(0.290 * sx, FACE_Z + 0.044, 0.012)
        shine = ball("Shine" + side, pos, (0.014, 0.011, 0.016), rot=rot)
        shine.data.materials.append(white)
        parts += [eye, shine]
    pos, rot = on_face(0.0, FACE_Z - 0.042, -0.004)
    mouth = ball("Mouth", pos, (0.034, 0.020, 0.014), rot=rot)
    mouth.data.materials.append(pupil)
    parts.append(mouth)
    join_into(disc, parts)
    disc.name = "Face"
    return set_group(disc, {"Chest": 1.0})


def build_costume():
    """固定色の装飾: 顔まわりのピンク・袖から出た腕・カフス・爪・トゲ・お腹のボタン・耳。
    パーツごとに追従ボーンが違うので、結合前に頂点グループを入れておく。"""
    skin, claw_mat = make_mat("Skin"), make_mat("Claw")
    parts = []

    # 顔穴のふちを飾るピンクのリング
    bpy.ops.mesh.primitive_torus_add(major_radius=FACE_HOLE_R + 0.010, minor_radius=0.050,
                                     major_segments=28, minor_segments=10,
                                     location=(0.0, -0.348, FACE_Z),
                                     rotation=(math.radians(90), 0.0, 0.0))
    ring = bpy.context.object
    ring.name = "FaceRing"
    bake(ring, loc=(0.0, -0.348, FACE_Z), rot=(math.radians(90), 0.0, 0.0))
    for poly in ring.data.polygons:
        poly.use_smooth = True
    ring.data.materials.append(skin)
    parts.append(set_group(ring, {"Chest": 1.0}))

    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        loc, rot = arm_transform(sx)
        arm = bake(lathe("Skin" + side, SKIN_ARM, 16), loc=loc, rot=rot)
        arm.data.materials.append(skin)
        parts.append(set_group(arm, {"UpperArm." + side: 1.0}))

        bpy.ops.mesh.primitive_torus_add(major_radius=0.096, minor_radius=0.028,
                                         major_segments=16, minor_segments=8)
        cuff = bpy.context.object
        cuff.name = "Cuff" + side
        bake(cuff, loc=(0.0, 0.0, WRIST_Z))
        bake(cuff, loc=loc, rot=rot)
        for poly in cuff.data.polygons:
            poly.use_smooth = True
        cuff.data.materials.append(make_mat("SpikePurple"))
        parts.append(set_group(cuff, {"UpperArm." + side: 1.0}))

        # ミトンの先の白い爪
        for i, dx in enumerate((-0.055, 0.0, 0.055)):
            nail = cone("HandClaw%s%d" % (side, i), 0.024, 0.052, segments=8)
            bake(nail, loc=(dx, -0.050, -0.450), rot=(math.radians(-118.0), 0.0, 0.0))
            bake(nail, loc=loc, rot=rot)
            nail.data.materials.append(claw_mat)
            parts.append(set_group(nail, {"Hand." + side: 1.0}))

        # ブーツのつま先の爪
        for i, dx in enumerate((-0.058, 0.0, 0.058)):
            toe = cone("ToeClaw%s%d" % (side, i), 0.026, 0.056, segments=8)
            bake(toe, loc=(HIP_X * sx + dx, -0.240, 0.076),
                 rot=(math.radians(-100.0), 0.0, 0.0))
            toe.data.materials.append(claw_mat)
            parts.append(set_group(toe, {"Foot." + side: 1.0}))

    # 背びれ（頭頂から背中へ）。フード上は生地の厚みぶん外へ出す
    for i, (z, color) in enumerate(SPIKES):
        pos, normal, frame = surface_frame(z, math.pi)
        push = HOOD_OUT + HOOD_THICK * 0.0 if z >= HOOD_Z0 else 0.0
        spike = cone("Spike%d" % i, 0.058, 0.105, segments=10)
        bake(spike, loc=tuple(pos + normal * push), rot=frame)
        spike.data.materials.append(make_mat(color))
        bone = "Chest" if z >= 1.06 else ("Spine" if z >= 0.86 else "Hips")
        parts.append(set_group(spike, {bone: 1.0}))

    # お腹のパステルなボタン
    for i, (z, color) in enumerate(BELLY):
        pos, normal, frame = surface_frame(z, 0.0)
        button = ball("Belly%d" % i, tuple(pos + normal * 0.004), (0.050, 0.064, 0.024),
                      rot=frame)
        button.data.materials.append(make_mat(color))
        parts.append(set_group(button, {"Spine" if z >= 0.86 else "Hips": 1.0}))

    costume = parts[0]
    join_into(costume, parts[1:])
    costume.name = "Costume"
    return costume


# =====================================================================
# 組み立て
# =====================================================================

def build():
    clear_scene()
    body, hood = build_body(), build_hood()
    tail, tail_spikes = build_tail()
    face, costume = build_face(), build_costume()

    rig = build_armature()
    parent_to_rig(rig, body, 'ARMATURE_AUTO')
    snap_head_to_chest(body)

    # フード・しっぽはボディと同じスーツ色なので Body に合流させる。
    # 自動ウェイトに任せると内側の面がボディと干渉するため、ここだけ手で振り分ける
    set_group_ramp(hood, "Spine", "Chest", HOOD_Z0, 1.18)
    set_group(tail, {"Hips": 1.0})
    for spike in tail_spikes:
        set_group(spike, {"Hips": 1.0})
    join_into(body, [hood, tail] + tail_spikes)
    cleanup(body)
    for poly in body.data.polygons:
        poly.material_index = 0

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
        render_previews(argv[argv.index("--render") + 1], "dino")


main()
