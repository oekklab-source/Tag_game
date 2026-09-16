"""スキン共通の骨格・リグ・アニメ・書き出し。

キャラの着せ替え（恐竜きぐるみ / 忍び装束 ...）で違うのはメッシュと配色だけで、
豆型のプロポーション・ボーン・アニメクリップは全スキンで同一。ここを共有すれば
新しい服は「パーツを組んで色を塗る」だけで済み、アニメは触らなくてよい。

ビルドスクリプト側は先頭で set_palette() を呼んでから make_mat() を使う。
Blender の -P はスクリプトのディレクトリを sys.path に入れないので、
呼ぶ側が sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))) すること。
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# ---- 全体プロポーション（Blender は Z-up・-Y が正面。全高およそ 1.74m）----
BODY_Z0, BODY_Z1, BODY_R = 0.50, 1.62, 0.40
HOOD_Z0 = 1.02                      # フードの裾
HOOD_OUT, HOOD_THICK = 0.034, 0.030  # 体表からの浮きと生地の厚み
FACE_Z, FACE_HOLE_R = 1.30, 0.205    # 顔穴の中心高さと半径
SHOULDER_X, SHOULDER_Z = 0.355, 1.15
ARM_TILT, ARM_SPLAY = -0.12, 0.46    # 前へ垂らす角 / 横へ開く角
WRIST_Z = -0.260                     # 袖口の位置（腕ローカル座標。ここから先がミトン）
HIP_X = 0.175


# ---- 配色パレット（スキンごとにビルドスクリプトが差し込む）----
_COLORS, _EMISSION, _EMISSION_DEFAULT = {}, {}, 0.35


def set_palette(colors, emission, default=0.35):
    """make_mat() が引く色表を差し替える。各ビルドスクリプトが冒頭で一度だけ呼ぶ。"""
    global _COLORS, _EMISSION, _EMISSION_DEFAULT
    _COLORS, _EMISSION, _EMISSION_DEFAULT = colors, emission, default


# =====================================================================
# 汎用ジオメトリヘルパ
# =====================================================================

def make_mat(name):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    rgb = _COLORS[name]
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.45
    strength = _EMISSION.get(name, _EMISSION_DEFAULT)
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


# 豆型ボディの輪郭。フード・顔の帯もこれを offset して作る
BODY_PROFILE = superellipse(BODY_Z0, BODY_Z1, BODY_R, 2.9, 2.1, rows=20)


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
# バナナで足をすくわれて顔から突っ込む。長さは banana.gd の STUN(1.5秒) = 45フレームに合わせ、
# 最後のキーを Idle の 0 フレーム目と同じにして、スタンが明けた瞬間の Idle へ滑らかに繋ぐ。
#
# 体を倒すのは **Root の X 回転（正が前傾）**。Dive と違って親ノードの rotation.x は
# 触らない（あれは Dive 専用）。アニメの中だけで完結させれば、同じ Humanoid を使う
# CPU 逃走者・CPU 鬼にも手を入れずに同じ転び方が乗る。
#
# Root の回転の支点は bone head = 足元なので、倒し切ると体の中心線が床(0)に来てしまう。
# 体の半径は 0.40 あるので up() で 0.35〜0.42 持ち上げ、腹が床に乗る高さにする
# （この値はキーごとにポーズを付けたメッシュの最下点 Z を実測して決めた）。
# loc は自分の回転の影響を受けない（rest 軸のまま）ので、何度倒しても up() は世界の上下。
#
# 倒れると軸が寝るので、意味が変わる角度がある:
#   ・Thigh の正値（後ろ）= 脚が**上へ**跳ね上がる
#   ・Chest の負値（後ろに反る）= 顔が**上がる**
# 腕は倒れた後に X の負値（前）を使うと**体の下へ潜って見えなくなる**ので、
# 着地からは Z を ±84 まで開いて大の字に寝かせる。
# 顔面着地のつぶれは Spine の **scale Z（前後）** を縮めて作る（尻もちなら Y だった）
SLIP = {
    # 踏んだ瞬間。足が前へすっぽ抜け、腕が後ろへ跳ね上がって上体が置いていかれる
    0: {"Root": {"rot": (8, 0, 0), "loc": up(0.0)}, "Spine": (-6, 0, 0), "Chest": (-4, 0, 0),
        "Thigh.L": (-60, 0, 0), "Shin.L": (-4, 0, 0), "Foot.L": (-28, 0, 0),
        "Thigh.R": (-20, 0, 0), "Shin.R": (10, 0, 0), "Foot.R": (-8, 0, 0),
        "UpperArm.L": (45, 0, -50), "UpperArm.R": (45, 0, 50),
        "Hand.L": (0, 0, -12), "Hand.R": (0, 0, 12)},
    # 前へつんのめる。足が地面を離れ、腕が前へ出はじめる
    3: {"Root": {"rot": (38, 0, 0), "loc": up(0.13)}, "Spine": (-4, 0, 0), "Chest": (2, 0, 0),
        "Thigh.L": (-20, 0, 0), "Shin.L": (10, 0, 0), "Foot.L": (-16, 0, 0),
        "Thigh.R": (10, 0, 0), "Shin.R": (20, 0, 0), "Foot.R": (-16, 0, 0),
        "UpperArm.L": (-30, 0, -40), "UpperArm.R": (-30, 0, 40),
        "Hand.L": (0, 0, -16), "Hand.R": (0, 0, 16)},
    # 空中でほぼ水平。腕は前ではなく斜め横へ開きはじめ、脚は後ろ（＝上）へ跳ね上がる
    6: {"Root": {"rot": (78, 0, 0), "loc": up(0.30)},
        "Spine": {"rot": (-8, 0, 0), "scale": (0.98, 1.04, 0.98)}, "Chest": (-12, 0, 0),
        "Thigh.L": (25, 0, -3), "Shin.L": (-10, 0, 0), "Foot.L": (-20, 0, 0),
        "Thigh.R": (25, 0, 3), "Shin.R": (-10, 0, 0), "Foot.R": (-20, 0, 0),
        "UpperArm.L": (-40, 0, -62), "UpperArm.R": (-40, 0, 62),
        "Hand.L": (0, 0, -10), "Hand.R": (0, 0, 10)},
    # 顔面着地。水平まで倒し切って前後に潰れ、腕は大の字に開き、脚は跳ね上がる
    9: {"Root": {"rot": (91, 0, 0), "loc": up(0.42)},
        "Spine": {"rot": (-4, 0, 0), "scale": (1.12, 1.0, 0.84)}, "Chest": (-10, 0, 0),
        "Thigh.L": (34, 0, -6), "Shin.L": (30, 0, 0), "Foot.L": (-30, 0, 0),
        "Thigh.R": (34, 0, 6), "Shin.R": (30, 0, 0), "Foot.R": (-30, 0, 0),
        "UpperArm.L": (-14, 0, -84), "UpperArm.R": (-14, 0, 84),
        "Hand.L": (0, 0, -24), "Hand.R": (0, 0, 24)},
    # 反動。潰れが戻って体が少し浮き、脚が下りてくる
    12: {"Root": {"rot": (84, 0, 0), "loc": up(0.36)},
         "Spine": {"rot": (-10, 0, 0), "scale": (0.96, 1.0, 1.06)}, "Chest": (-6, 0, 0),
         "Thigh.L": (16, 0, -5), "Shin.L": (16, 0, 0), "Foot.L": (-18, 0, 0),
         "Thigh.R": (16, 0, 5), "Shin.R": (16, 0, 0), "Foot.R": (-18, 0, 0),
         "UpperArm.L": (-10, 0, -80), "UpperArm.R": (-10, 0, 80),
         "Hand.L": (0, 0, -16), "Hand.R": (0, 0, 16)},
    # べたっ。大の字で伸びきる（ここから 33 までが一番長い「間」）
    15: {"Root": {"rot": (88, 0, 0), "loc": up(0.385)},
         "Spine": {"rot": (-6, 0, 0), "scale": (1.04, 1.0, 0.94)}, "Chest": (-8, 0, 0),
         "Thigh.L": (6, 0, -14), "Shin.L": (10, 0, 0), "Foot.L": (-14, 0, 0),
         "Thigh.R": (6, 0, 14), "Shin.R": (10, 0, 0), "Foot.R": (-14, 0, 0),
         "UpperArm.L": (-8, 0, -84), "UpperArm.R": (-8, 0, 84),
         "Hand.L": (0, 0, -14), "Hand.R": (0, 0, 14)},
    # ぴくっ。左右を非対称に動かさないと、伸びている間が「止め絵」に見える
    22: {"Root": {"rot": (88, 0, 0), "loc": up(0.39)},
         "Spine": {"rot": (-6, 0, 0), "scale": (1.03, 1.0, 0.95)}, "Chest": (-6, 3, 0),
         "Thigh.L": (10, 0, -14), "Shin.L": (16, 0, 0), "Foot.L": (-14, 0, 0),
         "Thigh.R": (3, 0, 14), "Shin.R": (8, 0, 0), "Foot.R": (-14, 0, 0),
         "UpperArm.L": (-8, 0, -84), "UpperArm.R": (-8, 0, 84),
         "Hand.L": (0, 0, -14), "Hand.R": (0, 0, 14)},
    # もう一度ぴくっ。今度は逆側
    28: {"Root": {"rot": (88, 0, 0), "loc": up(0.385)},
         "Spine": {"rot": (-6, 0, 0), "scale": (1.03, 1.0, 0.95)}, "Chest": (-4, -3, 0),
         "Thigh.L": (3, 0, -14), "Shin.L": (8, 0, 0), "Foot.L": (-14, 0, 0),
         "Thigh.R": (11, 0, 14), "Shin.R": (17, 0, 0), "Foot.R": (-14, 0, 0),
         "UpperArm.L": (-8, 0, -84), "UpperArm.R": (-8, 0, 84),
         "Hand.L": (0, 0, -14), "Hand.R": (0, 0, 14)},
    # 起き上がりの入り。腰を下げすぎると腹が床を掘るので、傾きより先に高さを残す
    31: {"Root": {"rot": (82, 0, 0), "loc": up(0.35)}, "Spine": (-8, 0, 0), "Chest": (-12, 0, 0),
         "Thigh.L": (4, 0, -8), "Shin.L": (12, 0, 0), "Foot.L": (-12, 0, 0),
         "Thigh.R": (6, 0, 8), "Shin.R": (14, 0, 0), "Foot.R": (-12, 0, 0),
         "UpperArm.L": (-40, 0, -60), "UpperArm.R": (-40, 0, 60),
         "Hand.L": (0, 0, -18), "Hand.R": (0, 0, 18)},
    # 顔を上げ、手をついて体を起こしにかかる
    33: {"Root": {"rot": (72, 0, 0), "loc": up(0.19)}, "Spine": (-14, 0, 0), "Chest": (-16, 0, 0),
         "Thigh.L": (2, 0, -6), "Shin.L": (20, 0, 0), "Foot.L": (-10, 0, 0),
         "Thigh.R": (2, 0, 6), "Shin.R": (20, 0, 0), "Foot.R": (-10, 0, 0),
         "UpperArm.L": (-60, 0, -30), "UpperArm.R": (-60, 0, 30),
         "Hand.L": (0, 0, -20), "Hand.R": (0, 0, 20)},
    # 上体を起こしながら膝を胸へたたむ。ここを通さないと、脚が床を突き抜けて回る
    36: {"Root": {"rot": (50, 0, 0), "loc": up(0.22)}, "Spine": (-4, 0, 0), "Chest": (-6, 0, 0),
         "Thigh.L": (-30, 0, -4), "Shin.L": (46, 0, 0), "Foot.L": (0, 0, 0),
         "Thigh.R": (-28, 0, 4), "Shin.R": (44, 0, 0), "Foot.R": (0, 0, 0),
         "UpperArm.L": (-40, 0, -26), "UpperArm.R": (-40, 0, 26)},
    # 膝を立てて前かがみになり、立ち上がりにかかる
    38: {"Root": {"rot": (30, 0, 0), "loc": up(0.14)}, "Spine": (6, 0, 0), "Chest": (10, 0, 0),
         "Thigh.L": (-55, 0, 0), "Shin.L": (72, 0, 0), "Foot.L": (10, 0, 0),
         "Thigh.R": (-52, 0, 0), "Shin.R": (70, 0, 0), "Foot.R": (10, 0, 0),
         "UpperArm.L": (25, 0, -20), "UpperArm.R": (25, 0, 20)},
    # 立ち上がり途中
    42: {"Root": {"rot": (8, 0, 0), "loc": up(0.04)}, "Spine": (6, 0, 0), "Chest": (2, 0, 0),
         "Thigh.L": (-22, 0, 0), "Shin.L": (34, 0, 0), "Foot.L": (6, 0, 0),
         "Thigh.R": (-20, 0, 0), "Shin.R": (32, 0, 0), "Foot.R": (6, 0, 0),
         "UpperArm.L": (10, 0, -10), "UpperArm.R": (10, 0, 10)},
    # Idle の 0 フレーム目と同じポーズ。ここで終われば Idle へのブレンドが目立たない
    45: {"Chest": (2, 0, 0), "UpperArm.L": (4, 0, -4), "UpperArm.R": (4, 0, 4)},
}

# --- エモート -----------------------------------------------------------
# どちらも「立ち止まって出す」ものなので、脚は軽く曲げる程度に留めて上半身で見せる。
# ループ前提（ゲーム側が数秒間まわす）なので、最初と最後のキーは必ず同じポーズにする。
#
# 腕を上げるのは **Z（横に開く）** で行うこと。X は前後の振り（Run の腕振り）で、
# 大きな負値を入れると腕が体の内側へ回り込んで**顔の前で交差する**。
# 基準は Jump の Z=±78 で、これがちょうど水平。0 が下ろした状態なので、
# Z≈110 で斜め上、Z≈150 でほぼ真上になる。

# 「ナイス！」= 両腕を斜め上に開いて跳ねるガッツポーズ（バンザイ）。
# 肩幅が広くフードが大きいので、真上まで上げると頭に埋まる。V字に開いて見せる
NICE_DOWN = {
    "UpperArm.L": (-4, 0, -104), "UpperArm.R": (-4, 0, 104),
    "Hand.L": (0, 0, -14), "Hand.R": (0, 0, 14),
    "Spine": {"rot": (-3, 0, 0), "scale": (1.032, 0.952, 1.032)}, "Chest": (-4, 0, 0),
    "Thigh.L": (-16, 0, 0), "Shin.L": (26, 0, 0), "Foot.L": (-10, 0, 0),
    "Thigh.R": (-16, 0, 0), "Shin.R": (26, 0, 0), "Foot.R": (-10, 0, 0),
    "Root": {"loc": up(-0.032)},
}
NICE_UP = {
    "UpperArm.L": (-8, 0, -134), "UpperArm.R": (-8, 0, 134),
    "Hand.L": (0, 0, -22), "Hand.R": (0, 0, 22),
    "Spine": {"rot": (-8, 0, 0), "scale": (0.956, 1.072, 0.956)}, "Chest": (-9, 0, 0),
    "Thigh.L": (-6, 0, 0), "Shin.L": (10, 0, 0), "Foot.L": (6, 0, 0),
    "Thigh.R": (-6, 0, 0), "Shin.R": (10, 0, 0), "Foot.R": (6, 0, 0),
    "Root": {"loc": up(0.086)},
}

# 「カモン！」= 挑発モーション。プレイヤーが 1/2/3 で3つの型から選ぶ
# （player.gd の taunt_style）。どれも「呼ぶ」より「煽る」動きにしてある。
#
# 3種に共通する作りかた:
#   ・腕を前へ出すのは X の**負値**。ただし Z を 40 以上開いておかないと
#     腕が体の内側へ回り込んで顔の前で交差する
#   ・肘ボーンが無い（UpperArm -> Hand の2段）ので「腰に手を当てる」は作れない。
#     左腕は体側に下ろして手首だけ内へ折り、脱力した余裕として見せる
#   ・キーの間隔をわざと不均等にする。等間隔で往復させると機械的な素振りになり、
#     人が煽っている感じ（＝うざさ）が出ない
#   ・手首の招きは Hand の X。負で開き、正で体側へ折る

# 型1「前のめり」= 上体を倒して顔を突き出し、右手の手首でクイクイと速く2回招く。
# 体を左右にゆらしながら膝の屈伸で小刻みに弾む。24フレーム = 0.8秒。
# 16 -> 24 の8フレームだけ長く取り、「2回招いてから溜める」リズムにしている
TAUNT_LEAN = {
    # 構え。上体を前へ倒して顔を突き出し、手首は開いたまま
    0: {"Spine": {"rot": (7, 9, 0)}, "Chest": (16, 6, 0),
        "UpperArm.R": (-58, 0, 80), "Hand.R": (-46, 0, 0),
        "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
        "Thigh.L": (-16, 0, 0), "Shin.L": (26, 0, 0), "Foot.L": (-8, 0, 0),
        "Thigh.R": (-16, 0, 0), "Shin.R": (26, 0, 0), "Foot.R": (-8, 0, 0),
        "Root": {"loc": up(-0.055)}},
    # 1回目の「クイッ」。膝が伸びて体ごと前へ出る（手首だけ動かすと弱い）
    4: {"Spine": {"rot": (11, 5, 0), "scale": (0.985, 1.032, 0.985)}, "Chest": (21, 3, 0),
        "UpperArm.R": (-46, 0, 80), "Hand.R": (42, 0, 0),
        "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
        "Thigh.L": (-8, 0, 0), "Shin.L": (12, 0, 0), "Foot.L": (-4, 0, 0),
        "Thigh.R": (-8, 0, 0), "Shin.R": (12, 0, 0), "Foot.R": (-4, 0, 0),
        "Root": {"loc": up(-0.018)}},
    # 沈んで戻す
    8: {"Spine": {"rot": (7, 0, 0)}, "Chest": (16, 0, 0),
        "UpperArm.R": (-58, 0, 80), "Hand.R": (-46, 0, 0),
        "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
        "Thigh.L": (-16, 0, 0), "Shin.L": (26, 0, 0), "Foot.L": (-8, 0, 0),
        "Thigh.R": (-16, 0, 0), "Shin.R": (26, 0, 0), "Foot.R": (-8, 0, 0),
        "Root": {"loc": up(-0.055)}},
    # 2回目の「クイッ」。1回目と逆側へひねって同じ動きに見せない
    12: {"Spine": {"rot": (11, -5, 0), "scale": (0.985, 1.032, 0.985)}, "Chest": (21, -3, 0),
         "UpperArm.R": (-46, 0, 80), "Hand.R": (42, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-8, 0, 0), "Shin.L": (12, 0, 0), "Foot.L": (-4, 0, 0),
         "Thigh.R": (-8, 0, 0), "Shin.R": (12, 0, 0), "Foot.R": (-4, 0, 0),
         "Root": {"loc": up(-0.018)}},
    # 招き終わり。ここから 24 までの8フレームが「溜め」で、ゆっくり構えへ戻る
    16: {"Spine": {"rot": (7, -9, 0)}, "Chest": (16, -6, 0),
         "UpperArm.R": (-58, 0, 80), "Hand.R": (-46, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-16, 0, 0), "Shin.L": (26, 0, 0), "Foot.L": (-8, 0, 0),
         "Thigh.R": (-16, 0, 0), "Shin.R": (26, 0, 0), "Foot.R": (-8, 0, 0),
         "Root": {"loc": up(-0.050)}},
    24: {"Spine": {"rot": (7, 9, 0)}, "Chest": (16, 6, 0),
         "UpperArm.R": (-58, 0, 80), "Hand.R": (-46, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-16, 0, 0), "Shin.L": (26, 0, 0), "Foot.L": (-8, 0, 0),
         "Thigh.R": (-16, 0, 0), "Shin.R": (26, 0, 0), "Foot.R": (-8, 0, 0),
         "Root": {"loc": up(-0.055)}},
}

# 型2「腰ふり」= 腰を左右に振りながら、両手を胸の前でクイクイ。
# Root の loc は第1要素が左右・第2要素が上下（up() が入れるのは第2要素）。
# 腰と上体を**逆**にひねると、振りが体の中で回って「おちょくり」になる。
# 20フレーム = 0.67秒で 左 -> 中 -> 右 -> 中 の1往復
TAUNT_HIP = {
    # 腰を左へ。手首は開いて次の招きに備える
    0: {"Root": {"loc": (0.055, -0.005, 0.0)},
        "Spine": {"rot": (6, -12, 0)}, "Chest": (12, -6, 0),
        "UpperArm.L": (-52, 0, -36), "Hand.L": (-42, 0, 0),
        "UpperArm.R": (-52, 0, 36), "Hand.R": (-42, 0, 0),
        "Thigh.L": (-14, 0, 0), "Shin.L": (22, 0, 0), "Foot.L": (-6, 0, 0),
        "Thigh.R": (-14, 0, 0), "Shin.R": (22, 0, 0), "Foot.R": (-6, 0, 0)},
    # 中央で跳ねながら両手を同時に折る
    5: {"Root": {"loc": (0.0, 0.048, 0.0)},
        "Spine": {"rot": (4, 0, 0), "scale": (0.972, 1.048, 0.972)}, "Chest": (10, 0, 0),
        "UpperArm.L": (-58, 0, -32), "Hand.L": (40, 0, 0),
        "UpperArm.R": (-58, 0, 32), "Hand.R": (40, 0, 0),
        "Thigh.L": (-4, 0, 0), "Shin.L": (6, 0, 0), "Foot.L": (0, 0, 0),
        "Thigh.R": (-4, 0, 0), "Shin.R": (6, 0, 0), "Foot.R": (0, 0, 0)},
    # 腰を右へ
    10: {"Root": {"loc": (-0.055, -0.005, 0.0)},
         "Spine": {"rot": (6, 12, 0)}, "Chest": (12, 6, 0),
         "UpperArm.L": (-52, 0, -36), "Hand.L": (-42, 0, 0),
         "UpperArm.R": (-52, 0, 36), "Hand.R": (-42, 0, 0),
         "Thigh.L": (-14, 0, 0), "Shin.L": (22, 0, 0), "Foot.L": (-6, 0, 0),
         "Thigh.R": (-14, 0, 0), "Shin.R": (22, 0, 0), "Foot.R": (-6, 0, 0)},
    15: {"Root": {"loc": (0.0, 0.048, 0.0)},
         "Spine": {"rot": (4, 0, 0), "scale": (0.972, 1.048, 0.972)}, "Chest": (10, 0, 0),
         "UpperArm.L": (-58, 0, -32), "Hand.L": (40, 0, 0),
         "UpperArm.R": (-58, 0, 32), "Hand.R": (40, 0, 0),
         "Thigh.L": (-4, 0, 0), "Shin.L": (6, 0, 0), "Foot.L": (0, 0, 0),
         "Thigh.R": (-4, 0, 0), "Shin.R": (6, 0, 0), "Foot.R": (0, 0, 0)},
    20: {"Root": {"loc": (0.055, -0.005, 0.0)},
         "Spine": {"rot": (6, -12, 0)}, "Chest": (12, -6, 0),
         "UpperArm.L": (-52, 0, -36), "Hand.L": (-42, 0, 0),
         "UpperArm.R": (-52, 0, 36), "Hand.R": (-42, 0, 0),
         "Thigh.L": (-14, 0, 0), "Shin.L": (22, 0, 0), "Foot.L": (-6, 0, 0),
         "Thigh.R": (-14, 0, 0), "Shin.R": (22, 0, 0), "Foot.R": (-6, 0, 0)},
}

# 型3「余裕」= 上体を反らして顎を上げ、見下ろしたまま右腕を大きく回して「来い来い」。
# 反りは Spine/Chest の**負値**（正が前傾）。ゆっくり大きく2回招くので、
# 前のめり・腰ふりとは速さで区別がつく。30フレーム = 1.0秒
TAUNT_COOL = {
    # 反って構える。腕は横上に開いたまま
    0: {"Spine": {"rot": (-8, -4, 0)}, "Chest": (-6, -6, 0),
        "UpperArm.R": (-36, 0, 84), "Hand.R": (-38, 0, 0),
        "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
        "Thigh.L": (-6, 0, 0), "Shin.L": (10, 0, 0),
        "Thigh.R": (-6, 0, 0), "Shin.R": (10, 0, 0),
        "Root": {"loc": up(0.012)}},
    # 腕を後ろへ引き寄せて「来い」。同時に体重を後ろへ落とす
    8: {"Spine": {"rot": (-11, -2, 0), "scale": (1.028, 0.958, 1.028)}, "Chest": (-9, -3, 0),
        "UpperArm.R": (-10, 0, 90), "Hand.R": (44, 0, 0),
        "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
        "Thigh.L": (-12, 0, 0), "Shin.L": (20, 0, 0),
        "Thigh.R": (-12, 0, 0), "Shin.R": (20, 0, 0),
        "Root": {"loc": up(-0.020)}},
    # 開き直す。ひねりは逆側にして単なる往復に見せない
    15: {"Spine": {"rot": (-8, 4, 0)}, "Chest": (-6, 6, 0),
         "UpperArm.R": (-36, 0, 84), "Hand.R": (-38, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-6, 0, 0), "Shin.L": (10, 0, 0),
         "Thigh.R": (-6, 0, 0), "Shin.R": (10, 0, 0),
         "Root": {"loc": up(0.012)}},
    23: {"Spine": {"rot": (-11, 2, 0), "scale": (1.028, 0.958, 1.028)}, "Chest": (-9, 3, 0),
         "UpperArm.R": (-10, 0, 90), "Hand.R": (44, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-12, 0, 0), "Shin.L": (20, 0, 0),
         "Thigh.R": (-12, 0, 0), "Shin.R": (20, 0, 0),
         "Root": {"loc": up(-0.020)}},
    30: {"Spine": {"rot": (-8, -4, 0)}, "Chest": (-6, -6, 0),
         "UpperArm.R": (-36, 0, 84), "Hand.R": (-38, 0, 0),
         "UpperArm.L": (6, 0, -6), "Hand.L": (0, 0, -10),
         "Thigh.L": (-6, 0, 0), "Shin.L": (10, 0, 0),
         "Thigh.R": (-6, 0, 0), "Shin.R": (10, 0, 0),
         "Root": {"loc": up(0.012)}},
}

CLIPS = {
    "Idle": (IDLE, True),
    "Run": ({0: RUN_CONTACT, 6: RUN_PASS, 12: mirror(RUN_CONTACT), 18: mirror(RUN_PASS),
             24: RUN_CONTACT}, True),
    "Jump": ({0: JUMP_A, 10: JUMP_B, 20: JUMP_A}, True),
    "Dive": (DIVE, False),
    "Slip": (SLIP, False),
    # 1.2秒で2回跳ねる
    "Nice": ({0: NICE_DOWN, 9: NICE_UP, 18: NICE_DOWN, 27: NICE_UP, 36: NICE_DOWN}, True),
    # カモン（挑発）3種。humanoid.gd の EMOTE_ANIM がこの名前を引く
    "Come": (TAUNT_LEAN, True),
    "ComeHip": (TAUNT_HIP, True),
    "ComeCool": (TAUNT_COOL, True),
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
# 書き出し
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30


def export_glb(blend_path, glb_path):
    os.makedirs(os.path.dirname(glb_path), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    bpy.ops.export_scene.gltf(
        filepath=glb_path, export_format='GLB', export_yup=True, export_apply=True,
        export_skins=True, export_rest_position_armature=True, export_animations=True,
        export_animation_mode='NLA_TRACKS', export_bake_animation=False,
        export_optimize_animation_size=False, export_cameras=False, export_lights=False,
        export_materials='EXPORT', export_texcoords=False,
        use_visible=False, use_selection=False)
    print("saved  :", blend_path)
    print("export :", glb_path, os.path.getsize(glb_path), "bytes")


def render_previews(out_dir, prefix):
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
        scene.render.filepath = os.path.join(out_dir, "%s_%s.png" % (prefix, name))
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)
