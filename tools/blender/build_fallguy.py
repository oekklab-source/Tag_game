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

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "fallguy.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "character", "fallguy.glb")

# ---- 全体プロポーション（Blender は Z-up・-Y が正面。全高およそ 1.74m）----
BODY_Z0, BODY_Z1, BODY_R = 0.50, 1.62, 0.40
HOOD_Z0 = 1.02                      # フードの裾
HOOD_OUT, HOOD_THICK = 0.034, 0.030  # 体表からの浮きと生地の厚み
FACE_Z, FACE_HOLE_R = 1.30, 0.205    # 顔穴の中心高さと半径
SHOULDER_X, SHOULDER_Z = 0.355, 1.15
ARM_TILT, ARM_SPLAY = -0.12, 0.46    # 前へ垂らす角 / 横へ開く角
WRIST_Z = -0.260                     # 袖口の位置（腕ローカル座標。ここから先がミトン）
HIP_X = 0.175

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


# =====================================================================
# 汎用ジオメトリヘルパ
# =====================================================================

def make_mat(name):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    rgb = COLORS[name]
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.45
    strength = EMISSION.get(name, EMISSION_DEFAULT)
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = strength
    mat.diffuse_color = (*rgb, 1.0)
    return mat


def lathe(name, profile, segments=24):
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
        poly.use_smooth = True
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
    bpy.ops.object.select_all(action='DESELECT')
    for obj in others:
        obj.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()
    return target


def cleanup(obj):
    """ブーリアンや結合で出た重複頂点・不正な面を掃除する（glTF の検証警告対策）。"""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.validate(verbose=False)
    obj.data.update()
    return obj


def apply_mods(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    for mod in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def superellipse(z0, z1, rmax, n_low, n_up, rows=20):
    """極でなめらかに0へ収束する超楕円シルエット。極付近を細かくサンプルする。"""
    pts = []
    for i in range(rows + 1):
        t = 0.5 - 0.5 * math.cos(math.pi * i / rows)
        u = 2.0 * t - 1.0
        n = n_low if u < 0.0 else n_up
        pts.append((z0 + (z1 - z0) * t, max(rmax * (1.0 - abs(u) ** n) ** (1.0 / n), 0.0)))
    pts[0], pts[-1] = (z0, 0.0), (z1, 0.0)
    return pts


SPHERE = superellipse(-1.0, 1.0, 1.0, 2.0, 2.0, rows=12)


def ball(name, center, scale, rot=(0, 0, 0), segments=16):
    return bake(lathe(name, SPHERE, segments), loc=center, rot=rot, scale=scale)


def cone(name, base_r, height, segments=10, rows=5, sink=0.4):
    """トゲ・爪用の円錐（ローカル +Z が先端方向）。
    根元は太いまま体内へ sink ぶん埋めておかないと、表面に出た部分が細って見えなくなる。"""
    pts = [(-height * sink, 0.0), (-height * sink * 0.55, base_r * 0.9), (0.0, base_r)]
    pts += [(height * i / rows, base_r * (1.0 - i / rows) ** 0.8) for i in range(1, rows)]
    pts.append((height, 0.0))
    return lathe(name, pts, segments)


def cap(z_center, radius, steps=6):
    """筒の端を半球で閉じる輪郭（平らな断面が見えないように）。"""
    return [(z_center - radius * math.sin(math.pi / 2 * (1 - i / steps)),
             radius * math.cos(math.pi / 2 * (1 - i / steps))) for i in range(steps + 1)]


def body_radius(z):
    t = (z - BODY_Z0) / (BODY_Z1 - BODY_Z0)
    u = max(-1.0, min(1.0, 2.0 * t - 1.0))
    n = 2.9 if u < 0.0 else 2.1
    return BODY_R * (1.0 - abs(u) ** n) ** (1.0 / n)


def offset_profile(profile, dist):
    """輪郭を法線方向へ押し出す。極では自然に丸いキャップになる。"""
    out = []
    for i, (z, r) in enumerate(profile):
        z0, r0 = profile[max(i - 1, 0)]
        z1, r1 = profile[min(i + 1, len(profile) - 1)]
        dz, dr = z1 - z0, r1 - r0
        length = math.hypot(dz, dr) or 1.0
        out.append((z - dist * dr / length, max(r + dist * dz / length, 0.0)))
    return out


def surface_frame(z, azimuth):
    """体表上の点・面法線・その法線へローカル +Z を向ける Euler を返す。
    トゲや爪、お腹のボタンを体表から生やすのに使う。"""
    eps = 0.004
    dr = body_radius(min(z + eps, BODY_Z1)) - body_radius(max(z - eps, BODY_Z0))
    length = math.hypot(2.0 * eps, dr) or 1.0
    n_r, n_z = 2.0 * eps / length, -dr / length
    radius = body_radius(z)
    pos = Vector((radius * math.sin(azimuth), -radius * math.cos(azimuth), z))
    normal = Vector((n_r * math.sin(azimuth), -n_r * math.cos(azimuth), n_z))
    return pos, normal, (math.atan2(n_r, n_z), 0.0, azimuth)


def arm_transform(sx):
    """腕のローカル空間 -> ワールドの (位置, 回転)。肩を原点、-Z を腕の伸びる向きとする。"""
    return (SHOULDER_X * sx, 0.0, SHOULDER_Z), (ARM_TILT, -ARM_SPLAY * sx, 0.0)


def arm_point(sx, local_z):
    """腕ローカルの高さ local_z にあたるワールド座標。ボーン位置を腕の角度に追従させる。"""
    from mathutils import Euler
    loc, rot = arm_transform(sx)
    return tuple(Vector(loc) + (Euler(rot, 'XYZ').to_matrix() @ Vector((0.0, 0.0, local_z))))


def set_group(obj, weights):
    """weights: {ボーン名: 重み} を全頂点に一括で入れる。剛体的な付属物用。"""
    for name, weight in weights.items():
        group = obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
        group.add(range(len(obj.data.vertices)), weight, 'REPLACE')
    return obj


def set_group_ramp(obj, lower, upper, z0, z1):
    """高さでなめらかに 2 ボーンへ振り分ける。フードの裾がボディとずれないように使う。"""
    g_low = obj.vertex_groups.get(lower) or obj.vertex_groups.new(name=lower)
    g_up = obj.vertex_groups.get(upper) or obj.vertex_groups.new(name=upper)
    for vert in obj.data.vertices:
        t = min(max((vert.co.z - z0) / (z1 - z0), 0.0), 1.0)
        t = t * t * (3.0 - 2.0 * t)
        g_up.add([vert.index], t, 'REPLACE')
        g_low.add([vert.index], 1.0 - t, 'REPLACE')
    return obj


# =====================================================================
# メッシュ
# =====================================================================

BODY_PROFILE = superellipse(BODY_Z0, BODY_Z1, BODY_R, 2.9, 2.1, rows=20)

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
# リグ
# =====================================================================

# 豆キャラは首がないので Chest が上半身ごと頭を兼ねる。
# 顔・フード・肩をすべて Chest 系にぶら下げると、頭を振っても顔が本体からズレない。
def bone_table():
    """腕のボーンは ARM_SPLAY / ARM_TILT から算出し、メッシュと必ず同じ軸に乗せる。"""
    bones = [
        ("Root", None, (0.000, 0.000, 0.000), (0.000, 0.000, 0.140), False),
        ("Hips", "Root", (0.000, 0.000, 0.620), (0.000, 0.000, 0.860), False),
        ("Spine", "Hips", (0.000, 0.000, 0.860), (0.000, 0.000, 1.060), True),
        ("Chest", "Spine", (0.000, 0.000, 1.060), (0.000, 0.000, 1.620), True),
    ]
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        shoulder, wrist, tip = arm_point(sx, 0.05), arm_point(sx, WRIST_Z), arm_point(sx, -0.44)
        bones += [
            ("Shoulder." + side, "Chest", (0.100 * sx, 0.0, 1.200), shoulder, False),
            ("UpperArm." + side, "Shoulder." + side, shoulder, wrist, True),
            ("Hand." + side, "UpperArm." + side, wrist, tip, True),
        ]
    for sx in (1.0, -1.0):
        side = "L" if sx > 0 else "R"
        bones += [
            ("Thigh." + side, "Hips", (0.142 * sx, 0.0, 0.659), (0.157 * sx, 0.0, 0.360), False),
            ("Shin." + side, "Thigh." + side,
             (0.157 * sx, 0.0, 0.360), (0.170 * sx, 0.0, 0.100), True),
            ("Foot." + side, "Shin." + side,
             (0.170 * sx, 0.0, 0.100), (0.175 * sx, -0.150, 0.075), True),
        ]
    return bones


ARM_BONES = {"Shoulder.L", "UpperArm.L", "Hand.L", "Shoulder.R", "UpperArm.R", "Hand.R"}


def build_armature():
    rig = bpy.data.objects.new("Armature", bpy.data.armatures.new("FallGuyRig"))
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    for name, parent, head, tail, connect in bone_table():
        bone = rig.data.edit_bones.new(name)
        bone.head, bone.tail = Vector(head), Vector(tail)
        if parent:
            bone.parent = rig.data.edit_bones[parent]
            bone.use_connect = connect
    # 腕は外へ開いているのでロール0だとローカルXが斜めになり、大きく振ると体を貫通する。
    # ローカルZを world +Y に揃えてローカルX ≒ world X（矢状面のきれいな前後振り）にする
    for name in ("UpperArm.L", "UpperArm.R", "Hand.L", "Hand.R"):
        rig.data.edit_bones[name].align_roll(Vector((0.0, 1.0, 0.0)))
    bpy.ops.object.mode_set(mode='OBJECT')
    return rig


def parent_to_rig(rig, mesh, kind):
    bpy.ops.object.select_all(action='DESELECT')
    mesh.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type=kind)


def snap_head_to_chest(mesh, z0=1.00, z1=1.18):
    """顔の高さのボディ頂点を Chest に寄せ、剛体バインドした顔・フードと一体で動かす。
    腕の頂点は肩越しに巻き込まないよう除外する。"""
    index = {g.name: g.index for g in mesh.vertex_groups}
    chest = mesh.vertex_groups["Chest"]
    for vert in mesh.data.vertices:
        weights = {g.group: g.weight for g in vert.groups}
        if sum(weights.get(index[n], 0.0) for n in ARM_BONES) > 0.15 or vert.co.z <= z0:
            continue
        t = min(1.0, (vert.co.z - z0) / (z1 - z0))
        t = t * t * (3.0 - 2.0 * t)
        for group in mesh.vertex_groups:
            if group.name == "Chest" or group.name in ARM_BONES:
                continue
            current = weights.get(group.index)
            if current:
                group.add([vert.index], current * (1.0 - t), 'REPLACE')
        chest.add([vert.index], max(weights.get(index["Chest"], 0.0), t), 'REPLACE')


# =====================================================================
# アニメーション（30fps）
# =====================================================================

def up(dz):
    """Root ボーンは +Z を向いているので、ローカル location.y が world の上下になる。"""
    return (0.0, dz, 0.0)


def mirror(pose):
    """L/R を入れ替えて左右反転したポーズを作る（Y/Z 回転と X 移動は符号反転）。"""
    out = {}
    for name, value in pose.items():
        flipped = name.replace(".L", ".@").replace(".R", ".L").replace(".@", ".R")
        if isinstance(value, dict):
            copy = dict(value)
            if "rot" in copy:
                r = copy["rot"]
                copy["rot"] = (r[0], -r[1], -r[2])
            if "loc" in copy:
                l = copy["loc"]
                copy["loc"] = (-l[0], l[1], l[2])
        else:
            copy = (value[0], -value[1], -value[2])
        out[flipped] = copy
    return out


IDLE = {
    0: {"Chest": (2, 0, 0), "UpperArm.L": (4, 0, -4), "UpperArm.R": (4, 0, 4)},
    15: {"Root": {"loc": up(0.022)}, "Spine": {"rot": (-1, 0, 0), "scale": (0.982, 1.035, 0.982)},
         "Chest": (-2, 0, 2), "UpperArm.L": (-7, 0, -8), "UpperArm.R": (-7, 0, 8),
         "Thigh.L": (2, 0, 0), "Thigh.R": (2, 0, 0)},
    30: {"Spine": {"scale": (1.014, 0.974, 1.014)}, "Chest": (4, 0, 0),
         "UpperArm.L": (7, 0, -2), "UpperArm.R": (7, 0, 2)},
    45: {"Root": {"loc": up(0.020)}, "Spine": {"rot": (-1, 0, 0), "scale": (0.984, 1.030, 0.984)},
         "Chest": (-2, 0, -2), "UpperArm.L": (-6, 0, -8), "UpperArm.R": (-6, 0, 8),
         "Thigh.L": (2, 0, 0), "Thigh.R": (2, 0, 0)},
    60: {"Chest": (2, 0, 0), "UpperArm.L": (4, 0, -4), "UpperArm.R": (4, 0, 4)},
}
# 走りの歩幅は「1周期で進む距離」を決め、そのままゲーム側の再生倍率に効く。
# 歩幅が足りないと、足がすべらない再生倍率が高くなりすぎて脚がブレて見える。
# 元は前脚の膝を大きく曲げていて 1周期 1.06m しかなく、7m/s で走るには
# 5.3倍速が必要だった（＝毎秒13歩）。前脚は膝を伸ばして遠くへ、
# 後脚は蹴り切って後ろへ流し、歩幅を稼いでいる。
# 実際の歩幅は tests/anim_stride.tscn が実測する
RUN_CONTACT = {  # 接地。沈み込む
    "Thigh.L": (-74, 0, 0), "Shin.L": (8, 0, 0), "Foot.L": (18, 0, 0),
    "Thigh.R": (60, 0, 0), "Shin.R": (2, 0, 0), "Foot.R": (-30, 0, 0),
    "UpperArm.L": (58, 0, -10), "UpperArm.R": (-64, 0, 10),
    "Spine": (-9, 0, 0), "Chest": {"rot": (-16, 0, -7)}, "Root": {"loc": up(0.0)},
}
RUN_PASS = {  # 通過姿勢。浮く
    "Thigh.L": (-14, 0, 0), "Shin.L": (86, 0, 0), "Foot.L": (6, 0, 0),
    "Thigh.R": (-10, 0, 0), "Shin.R": (-2, 0, 0), "Foot.R": (4, 0, 0),
    "UpperArm.L": (4, 0, -8), "UpperArm.R": (-10, 0, 8),
    "Spine": (-9, 0, 0), "Chest": {"rot": (-17, 0, 0), "scale": (0.985, 1.025, 0.985)},
    "Root": {"loc": up(0.072)},
}
# 肩が高く腕が短いので真上には振り上げられない。横に大きく開いて空中らしさを出す
JUMP_A = {
    "Thigh.L": (-34, 0, 0), "Shin.L": (48, 0, 0), "Thigh.R": (-26, 0, 0), "Shin.R": (40, 0, 0),
    "Foot.L": (14, 0, 0), "Foot.R": (12, 0, 0),
    "UpperArm.L": (-28, 0, -78), "UpperArm.R": (-28, 0, 78),
    "Spine": {"rot": (-4, 0, 0), "scale": (0.972, 1.052, 0.972)}, "Chest": (-6, 0, 0),
}
JUMP_B = {
    "Thigh.L": (-42, 0, 0), "Shin.L": (56, 0, 0), "Thigh.R": (-20, 0, 0), "Shin.R": (32, 0, 0),
    "Foot.L": (16, 0, 0), "Foot.R": (10, 0, 0),
    "UpperArm.L": (-40, 0, -70), "UpperArm.R": (-40, 0, 70),
    "Spine": {"rot": (-6, 0, 0), "scale": (0.986, 1.022, 0.986)}, "Chest": (-9, 0, 0),
}
# 親ノード側で -1.2rad 前傾させるので、ここでは体は倒さず手足だけ伸ばす
DIVE = {
    0: {"Chest": (0, 0, 0)},
    6: {"Thigh.L": (-26, 0, 0), "Shin.L": (40, 0, 0), "Thigh.R": (-26, 0, 0), "Shin.R": (40, 0, 0),
        "UpperArm.L": (48, 0, -12), "UpperArm.R": (48, 0, 12),
        "Spine": {"rot": (-10, 0, 0), "scale": (1.045, 0.935, 1.045)},
        "Root": {"loc": up(-0.035)}},
    14: {"Thigh.L": (18, 0, -4), "Shin.L": (-8, 0, 0), "Thigh.R": (18, 0, 4), "Shin.R": (-8, 0, 0),
         "UpperArm.L": (-90, 0, -16), "UpperArm.R": (-90, 0, 16),
         "Spine": {"rot": (4, 0, 0), "scale": (0.962, 1.058, 0.962)}, "Chest": (6, 0, 0)},
    22: {"Thigh.L": (26, 0, -6), "Shin.L": (-16, 0, 0), "Thigh.R": (26, 0, 6),
         "Shin.R": (-16, 0, 0), "Foot.L": (-22, 0, 0), "Foot.R": (-22, 0, 0),
         "UpperArm.L": (-99, 0, -10), "UpperArm.R": (-99, 0, 10),
         "Spine": (2, 0, 0), "Chest": (10, 0, 0)},
    30: {"Thigh.L": (22, 0, -6), "Shin.L": (-12, 0, 0), "Thigh.R": (22, 0, 6),
         "Shin.R": (-12, 0, 0), "Foot.L": (-18, 0, 0), "Foot.R": (-18, 0, 0),
         "UpperArm.L": (-95, 0, -12), "UpperArm.R": (-95, 0, 12),
         "Spine": (1, 0, 0), "Chest": (8, 0, 0)},
}
CLIPS = {
    "Idle": (IDLE, True),
    "Run": ({0: RUN_CONTACT, 6: RUN_PASS, 12: mirror(RUN_CONTACT), 18: mirror(RUN_PASS),
             24: RUN_CONTACT}, True),
    "Jump": ({0: JUMP_A, 10: JUMP_B, 20: JUMP_A}, True),
    "Dive": (DIVE, False),
}


def apply_pose(rig, pose):
    for bone in rig.pose.bones:
        bone.rotation_mode = 'XYZ'
        bone.rotation_euler = (0.0, 0.0, 0.0)
        bone.location = (0.0, 0.0, 0.0)
        bone.scale = (1.0, 1.0, 1.0)
    for name, value in pose.items():
        bone = rig.pose.bones[name]
        if isinstance(value, dict):
            if "rot" in value:
                bone.rotation_euler = [math.radians(a) for a in value["rot"]]
            if "loc" in value:
                bone.location = value["loc"]
            if "scale" in value:
                bone.scale = value["scale"]
        else:
            bone.rotation_euler = [math.radians(a) for a in value]
    bpy.context.view_layer.update()


def make_action(rig, name, keys, loop):
    """ブレンド時に前のアニメの値が残らないよう、全ボーンの全チャンネルを毎キー打つ。"""
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    anim = rig.animation_data or rig.animation_data_create()
    anim.action = action
    if anim.action_slot is None:
        anim.action_slot = action.slots.new(id_type='OBJECT', name=rig.name)
    slot = anim.action_slot
    for frame in sorted(keys):
        apply_pose(rig, keys[frame])
        for bone in rig.pose.bones:
            bone.keyframe_insert("location", frame=frame)
            bone.keyframe_insert("rotation_euler", frame=frame)
            bone.keyframe_insert("scale", frame=frame)
    action.use_frame_range = True
    action.frame_start, action.frame_end = min(keys), max(keys)
    action.use_cyclic = loop
    anim.action = None
    return action, slot


def push_nla(rig, made):
    """1トラック=1アクションにして、glTF で個別のアニメとして書き出せるようにする。"""
    anim = rig.animation_data or rig.animation_data_create()
    for track in list(anim.nla_tracks):
        anim.nla_tracks.remove(track)
    for action, slot in made:
        track = anim.nla_tracks.new()
        track.name = action.name
        strip = track.strips.new(action.name, int(action.frame_start), action)
        strip.name = action.name
        try:
            strip.action_slot = slot
        except (AttributeError, TypeError):
            pass
    anim.action = None


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30


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


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH, export_format='GLB', export_yup=True, export_apply=True,
        export_skins=True, export_rest_position_armature=True, export_animations=True,
        export_animation_mode='NLA_TRACKS', export_bake_animation=False,
        export_optimize_animation_size=False, export_cameras=False, export_lights=False,
        export_materials='EXPORT', export_texcoords=False,
        use_visible=False, use_selection=False)
    print("saved  :", BLEND_PATH)
    print("export :", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")


def render_previews(out_dir):
    """形の確認用プレビュー。バックグラウンドでも確実に動く Workbench で描く。"""
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
    cam.data.lens = 60
    scene.camera = cam
    angles = {"front": (90, 0, 0), "three": (78, 0, -40), "side": (90, 0, 90),
              "back": (84, 0, 190)}
    for name, deg in angles.items():
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, 0.88)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, 3.6))
        scene.render.filepath = os.path.join(out_dir, "dino_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    export()
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1])


main()
