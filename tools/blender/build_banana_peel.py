"""バナナの皮（罠アイテム）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_banana_peel.py

出力:
    tools/blender/banana_peel.blend  編集元（.gdignore で Godot のインポート対象外）
    assets/gimmicks/banana_peel.glb  Godot が読むモデル

第2版は「もっとリアルなものを」という要望を受けて作り直したもの。
前の版は断面 8 角形・区間ごとに直線でつないだ管で、低ポリのカクカクした
シルエットのままだった。今回は次の4点でよりリアルな見た目に寄せる。

  1. 背骨を Catmull-Rom スプラインで滑らかに補間してから掃引する
     （制御点は少数のまま、実際に生成される断面リングは密にする）。
  2. 断面を12角形に増やし、面をスムーズシェーディングして
     「丸みのある皮」らしい柔らかい陰影にする。
  3. 断面半径に3方向のうねり（リブ）を加え、完全な円柱ではなく
     本物のバナナ表皮に近い、わずかに稜のある断面にする。
  4. 各皮の先端は幅を絞りながら少し巻き戻す制御点を足すことで、
     実際に剥いた皮の先端が丸まる様子を再現する（Catmull-Rom が
     制御点の折り返しを自然な巻き込みとして補間してくれる）。

配色は前版を踏襲: 外側は濃い黄、裏返って見える内側は淡い黄、
先端は熟れた茶色、ヘタは緑から茶色へ。斑点は大きさと向きを不揃いにして
熟れ具合のムラを出し、外側の皮の質感はやや艶を強めた。

Godot 側の当たり判定は banana.tscn の CylinderShape3D
（半径 1.1 / 高さ 1.4）なので、モデルはおおよそ半径 1.2・高さ 0.9 に収める。
"""

import math
import os
import random

import bpy
from mathutils import Vector


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "banana_peel.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "banana_peel.glb")

PEEL_YELLOW = (0.96, 0.71, 0.03, 1.0)
INNER_YELLOW = (1.0, 0.92, 0.55, 1.0)
TIP_BROWN = (0.30, 0.14, 0.05, 1.0)
NECK_GREEN = (0.44, 0.64, 0.11, 1.0)

# 断面の分割数。12 + スムーズシェーディングで丸みのある印象になる。
RING = 12
# 背骨の制御点1区間あたりの補間ステップ数。増やすほど滑らかになる。
SPLINE_STEPS = 6
# 断面のうねり（皮のリブ）の本数と強さ。
RIDGE_COUNT = 3
RIDGE_AMPLITUDE = 0.05

# 皮の背骨の制御点。(中心からの距離, 高さ, 断面の幅) を根元から先端へ。
# 根元は少し高い一点に集めて、ヘタの下で皮がつながって見えるようにする。
# 末尾の3点は距離を減らしつつ高さを上げる「折り返し」で、剥けた皮の先端が
# くるりと巻き戻る様子を Catmull-Rom の補間だけで作る。先端の幅は根元の
# 半分程度までしか絞らない — 極端に細くすると「へたって垂れ下がった」
# 印象になるため、丸みを残したまま上向きに巻き込ませる。
# 本体。実が入っているので太く、地面まで長く寝る。
MAIN_SPINE = (
    (0.04, 0.58, 0.16),
    (0.16, 0.53, 0.30),
    (0.34, 0.44, 0.40),
    (0.56, 0.32, 0.45),
    (0.78, 0.20, 0.42),
    (0.97, 0.12, 0.30),
    (1.08, 0.08, 0.18),
    (1.14, 0.09, 0.10),
    (1.10, 0.19, 0.075),
    (1.02, 0.29, 0.06),
)
MAIN_FLATNESS = 0.78  # 断面の厚み ÷ 幅。1.0 で真円
MAIN_BROWN_FROM = 0.68

# 跳ね上がる皮。中ほどで一度地面近くまで下がり、先端がふっくらしたまま
# 上向きに反り返って巻く。
SIDE_SPINE = (
    (0.04, 0.58, 0.15),
    (0.14, 0.53, 0.27),
    (0.28, 0.45, 0.33),
    (0.44, 0.32, 0.31),
    (0.58, 0.19, 0.26),
    (0.68, 0.11, 0.18),
    (0.74, 0.09, 0.11),
    (0.71, 0.18, 0.08),
    (0.64, 0.26, 0.065),
)
SIDE_FLATNESS = 0.42
SIDE_BROWN_FROM = 0.80

# もっとも短い皮。地面に届かず途中でふっくらしたまま反り返って巻く。
SHORT_SPINE = (
    (0.04, 0.58, 0.14),
    (0.13, 0.53, 0.25),
    (0.24, 0.44, 0.28),
    (0.36, 0.31, 0.24),
    (0.46, 0.20, 0.18),
    (0.51, 0.15, 0.11),
    (0.48, 0.23, 0.08),
    (0.42, 0.30, 0.065),
)
SHORT_FLATNESS = 0.40
SHORT_BROWN_FROM = 0.82


def make_material(name, color, roughness=0.32):
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    shader = next(
        node for node in material.node_tree.nodes
        if node.type == "BSDF_PRINCIPLED"
    )
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    if "Coat Weight" in shader.inputs:
        shader.inputs["Coat Weight"].default_value = 0.25
    material.diffuse_color = color
    return material


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in list(bpy.data.collections):
        if collection.users == 0:
            bpy.data.collections.remove(collection)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def flatten(obj):
    for polygon in obj.data.polygons:
        polygon.use_smooth = False


def ring_angle(index):
    """断面上の角度。0 が真上（皮の外側）、pi が真下（皮の内側）。"""
    return (index + 0.5) * 2.0 * math.pi / RING


def catmull_rom(p0, p1, p2, p3, t):
    t2 = t * t
    t3 = t2 * t
    return 0.5 * (
        (2.0 * p1)
        + (p2 - p0) * t
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (3.0 * p1 - 3.0 * p2 - p0 + p3) * t3
    )


def resample_spine(spine, steps):
    """制御点の少ない背骨を、区間ごとに Catmull-Rom で補間して密にする。

    (半径, 高さ, 幅) を各成分ごとに独立して補間する。端点は複製して
    クランプし、両端がスプラインの制御点そのものに一致するようにする。
    幅は補間のオーバーシュートで負になり得るので下限を切る。
    """
    padded = (spine[0],) + tuple(spine) + (spine[-1],)
    resampled = []
    for i in range(1, len(padded) - 2):
        p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
        for step in range(steps):
            t = step / steps
            point = tuple(
                catmull_rom(p0[axis], p1[axis], p2[axis], p3[axis], t)
                for axis in range(3)
            )
            resampled.append((point[0], point[1], max(point[2], 0.035)))
    resampled.append(spine[-1])
    return resampled


def make_peel(name, angle_deg, spine, flatness, length_scale, materials, root,
              brown_from_ratio=None, ridge_phase=0.0):
    """皮を1枚、密に補間した背骨に沿って断面を掃引した管として作る。

    断面は上下に潰した楕円へ3方向のリブを重ねたもので、上を向く面が
    皮の外側、下を向く面が内側になる。brown_from_ratio (0-1) を渡すと、
    その位置から先端側が熟れた茶色になる。
    """
    dense_spine = resample_spine(spine, SPLINE_STEPS)
    brown_from = (
        None if brown_from_ratio is None
        else round((len(dense_spine) - 1) * brown_from_ratio)
    )

    angle = math.radians(angle_deg)
    radial = Vector((math.cos(angle), math.sin(angle), 0.0))
    side = Vector((-math.sin(angle), math.cos(angle), 0.0))
    centers = [radial * (radius * length_scale) + Vector((0.0, 0.0, height))
               for radius, height, _width in dense_spine]

    frames = []
    vertices = []
    for index, center in enumerate(centers):
        before = centers[max(index - 1, 0)]
        after = centers[min(index + 1, len(centers) - 1)]
        tangent = (after - before).normalized()
        normal = side.cross(tangent).normalized()
        if normal.z < 0.0:
            normal.negate()
        half_width = dense_spine[index][2] * 0.5
        half_thick = half_width * flatness
        frames.append((center, normal, half_width, half_thick))
        for ring in range(RING):
            theta = ring_angle(ring)
            ridge = 1.0 + RIDGE_AMPLITUDE * math.cos(
                RIDGE_COUNT * theta + ridge_phase)
            vertices.append(center
                            + side * (half_width * ridge * math.sin(theta))
                            + normal * (half_thick * ridge * math.cos(theta)))

    faces = []
    material_indices = []
    for index in range(len(centers) - 1):
        a, b = index * RING, (index + 1) * RING
        for ring in range(RING):
            following = (ring + 1) % RING
            faces.append((a + ring, a + following, b + following, b + ring))
            if brown_from is not None and index >= brown_from:
                material_indices.append(2)
            else:
                # 真下を向く帯だけが皮の内側（淡い黄）。真横の面まで淡くすると
                # 太い本体の側面が丸ごと色違いに見えてしまう。
                edge_angle = (ring + 1.0) * 2.0 * math.pi / RING
                material_indices.append(1 if math.cos(edge_angle) < -0.05 else 0)
    faces.append(tuple(reversed(range(RING))))
    material_indices.append(0)
    last = len(vertices) - RING
    faces.append(tuple(last + ring for ring in range(RING)))
    material_indices.append(2 if brown_from is not None else 0)

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    for material in materials:
        mesh.materials.append(material)
    for polygon, material_index in zip(mesh.polygons, material_indices):
        polygon.material_index = material_index
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    # 掃引面はスムーズシェーディングで丸みを出す。両端のふたは平らなまま
    # にしておいたほうが、極から広がる面の陰影が破綻しない。
    for polygon in obj.data.polygons[:-2]:
        polygon.use_smooth = True
    return {"object": obj, "frames": frames, "side": side}


def frame_at(peel, fraction):
    frames = peel["frames"]
    return frames[max(0, min(len(frames) - 1, round((len(frames) - 1) * fraction)))]


def add_cone(name, vertices, radius_bottom, radius_top, depth, z, material, root):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius_bottom,
        radius2=radius_top,
        depth=depth,
        location=(0.0, 0.0, z),
    )
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(material)
    obj.parent = root
    flatten(obj)
    modifier = obj.modifiers.new("Soft edges", "BEVEL")
    modifier.width = 0.012
    modifier.segments = 2
    modifier.limit_method = "ANGLE"
    return obj


def add_speckle(name, peel, fraction, theta_deg, radius, material, root,
                stretch=1.0, twist_deg=0.0):
    """皮の外側の面に熟れ斑点を貼る。大きさ・向き・伸び方を不揃いにして
    自然なムラに見せる。"""
    center, normal, half_width, half_thick = frame_at(peel, fraction)
    theta = math.radians(theta_deg)
    offset = (peel["side"] * (half_width * math.sin(theta))
              + normal * (half_thick * math.cos(theta)))
    facing = offset.normalized()
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=8,
        radius=radius,
        depth=0.008,
        location=center + offset + facing * 0.006,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale.x = stretch
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = facing.to_track_quat("Z", "Y")
    if twist_deg:
        obj.rotation_quaternion @= (
            Vector((0.0, 0.0, 1.0)).to_track_quat("Z", "Y").copy())
        obj.rotation_euler.rotate_axis("Z", math.radians(twist_deg))
        obj.rotation_mode = "QUATERNION"
    obj.data.materials.append(material)
    obj.parent = root
    flatten(obj)
    return obj


def build():
    random.seed(20260829)
    peel_material = make_material("BananaPeelOuter", PEEL_YELLOW, roughness=0.30)
    inner_material = make_material("BananaPeelInner", INNER_YELLOW, roughness=0.50)
    brown_material = make_material("BananaPeelTip", TIP_BROWN, roughness=0.62)
    green_material = make_material("BananaPeelNeck", NECK_GREEN, roughness=0.50)
    materials = (peel_material, inner_material, brown_material)

    root = bpy.data.objects.new("BananaPeel", None)
    bpy.context.collection.objects.link(root)

    # 参考画像の非対称なシルエット。長い本体を -X 寄りへ寝かせ、
    # 残り3枚を不均等な角度で跳ね上げる。
    main = make_peel("PeelMain", 205.0, MAIN_SPINE, MAIN_FLATNESS, 1.0,
                     materials, root, brown_from_ratio=MAIN_BROWN_FROM,
                     ridge_phase=0.0)
    right = make_peel("PeelRight", -25.0, SIDE_SPINE, SIDE_FLATNESS, 1.0,
                      materials, root, brown_from_ratio=SIDE_BROWN_FROM,
                      ridge_phase=0.9)
    left = make_peel("PeelLeft", 118.0, SIDE_SPINE, SIDE_FLATNESS, 0.88,
                     materials, root, brown_from_ratio=SIDE_BROWN_FROM,
                     ridge_phase=1.8)
    back = make_peel("PeelBack", 56.0, SHORT_SPINE, SHORT_FLATNESS, 0.92,
                     materials, root, brown_from_ratio=SHORT_BROWN_FROM,
                     ridge_phase=2.6)

    # 皮が集まる結び目と、その上のヘタ。上へ行くほど緑、先端は茶色。
    add_cone("Knot", 10, 0.15, 0.085, 0.16, 0.56, peel_material, root)
    add_cone("NeckGreen", 10, 0.085, 0.062, 0.10, 0.685, green_material, root)
    add_cone("Stem", 8, 0.055, 0.03, 0.10, 0.775, brown_material, root)

    # 斑点は大きさ・伸び・角度をばらけさせて、熟れムラらしい不揃いさにする。
    speckle_plan = (
        (main, 0.16, 24.0, 0.052, 1.3, 12),
        (main, 0.30, -32.0, 0.040, 0.8, -18),
        (main, 0.46, 20.0, 0.036, 1.6, 30),
        (main, 0.58, -12.0, 0.030, 1.0, -8),
        (right, 0.28, 26.0, 0.038, 1.2, 15),
        (right, 0.50, -20.0, 0.030, 0.9, -22),
        (left, 0.22, -24.0, 0.036, 1.1, 20),
        (left, 0.44, 18.0, 0.028, 1.4, -12),
        (back, 0.26, 22.0, 0.032, 1.0, 10),
        (back, 0.48, -18.0, 0.026, 1.2, -16),
    )
    for peel_index, (peel, fraction, theta, radius, stretch, twist) in enumerate(
            speckle_plan):
        add_speckle(f"Speckle{peel_index:02d}", peel, fraction, theta, radius,
                    brown_material, root, stretch=stretch, twist_deg=twist)

    bpy.context.view_layer.update()
    return root


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        export_apply=True,
        export_materials="EXPORT",
        export_texcoords=False,
        export_cameras=False,
        export_lights=False,
        use_visible=False,
        use_selection=False,
    )


def main():
    clear_scene()
    root = build()
    export()
    meshes = [child for child in root.children if child.type == "MESH"]
    result = {
        "root": root.name,
        "objects": [child.name for child in root.children],
        "blend_path": BLEND_PATH,
        "glb_path": GLB_PATH,
        "vertex_count": sum(len(child.data.vertices) for child in meshes),
        "polygon_count": sum(len(child.data.polygons) for child in meshes),
    }
    print(result)
    return result


result = main()
