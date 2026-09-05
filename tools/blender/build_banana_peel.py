"""バナナの皮（罠アイテム）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_banana_peel.py [-- --render <出力ディレクトリ>]

出力:
    tools/blender/banana_peel.blend  編集元（.gdignore で Godot のインポート対象外）
    assets/gimmicks/banana_peel.glb  Godot が読むモデル

第3版。前の版は皮を「閉じた12角形の管」として掃引していたため、1枚1枚が
ソーセージ状の棒に見えていた。皮の内側（淡い黄）が実際にはめくれて見えず、
「真下を向く帯だけ淡くする」という角度判定でごまかしていたのも同じ理由。

今回は断面そのものを作り直す。

  1. 断面を「C 字の樋」にする。外側の円弧と、そこから WALL だけ内側に
     オフセットした円弧の2枚を張り合わせ、長辺のリムと両端のふたで閉じる。
     こうすると外側＝濃い黄、内側＝淡い黄が形として分かれるので、
     色分けに角度判定が要らなくなり、参考画像のように平たくめくれて見える。
     開き角は 125 度と浅め。180 度を超えると半円管になり、結局
     ソーセージに戻ってしまう。先端側では開き角をさらに絞って
     ほぼ平らな刃にする（絞らないと樋の口とふたがかぎ爪に見える）。
  2. 背骨のサンプルごとに接線まわりの「ねじり（roll）」を持たせ、樋の開口が
     どちらを向くかを皮ごとに制御する。長い皮は 180 度ひねって黄色い外側を
     上に向け、跳ね上がる皮は開口を外へ向けて淡い内側の面を見せる。
  3. 皮が集まる中心を、立った胴体からヘタの先までを1本にした回転体
     （CORE_PROFILE）に置き換える。円錐を積み重ねると継ぎ目で陰影が割れる。
     参考画像の「立っている本体＋緑のヘタ」のシルエットはここで決まる。
  4. 熟れ斑点と断面リブは廃止。参考画像にはどちらも無く、ゲーム内の
     解像度では汚れにしか見えなかった。代わりに Roughness を下げて艶を出す。

Godot 側の当たり判定は banana.tscn の CylinderShape3D
（半径 1.1 / 高さ 1.4）なので、モデルはおおよそ半径 1.2・高さ 0.9 に収める。
"""

import math
import os
import sys

import bmesh
import bpy
import mathutils
from mathutils import Matrix, Vector


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "banana_peel.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "banana_peel.glb")

PEEL_YELLOW = (0.98, 0.76, 0.05, 1.0)
INNER_YELLOW = (0.97, 0.87, 0.53, 1.0)
TIP_BROWN = (0.26, 0.12, 0.04, 1.0)
NECK_GREEN = (0.42, 0.62, 0.12, 1.0)

# 樋の開き角と分割数。ここが見た目を決める最大の要素で、深くすると
# （180 度以上）皮が半円管になり「ソーセージ」に見えてしまう。125 度なら
# 反りの浅い平たい帯になり、参考画像の「めくれた皮」として読める。
ARC_SPAN = math.radians(125.0)
ARC_SEG = 6
# 先端側では開き角を絞って断面をほぼ平らな刃にする。開いたまま終わると、
# 樋の口とふたが「かぎ爪」のように見えてしまうため。
TIP_CLOSE_FROM = 0.72
TIP_CLOSE_SCALE = 0.28
# 皮の厚み。断面の外側円弧と内側円弧の半径差。
WALL = 0.022
# 背骨の制御点1区間あたりの補間ステップ数。増やすほど滑らかになる。
SPLINE_STEPS = 4
# この角度より折れている稜線だけ分割して、スムーズシェーディングでも
# リム（皮の縁）の折れ目が立つようにする。
SHARP_ANGLE = math.radians(30.0)

# 背骨の制御点 (中心からの距離, 高さ, 帯の幅) を根元から先端へ。
# 幅は樋の「差し渡し」で、円弧半径はここから逆算する。
# 末尾3点は距離を減らしつつ高さを上げる「折り返し」で、剥けた皮の先端が
# くるりと巻き戻る様子を Catmull-Rom の補間だけで作る。

# 地面に長く寝る皮。先端は茶色に熟れている。
LONG_SPINE = (
    (0.10, 0.53, 0.11),
    (0.16, 0.42, 0.26),
    (0.24, 0.29, 0.33),
    (0.38, 0.17, 0.36),
    (0.57, 0.09, 0.36),
    (0.77, 0.06, 0.32),
    (0.94, 0.055, 0.24),
    (1.04, 0.06, 0.15),
    (1.10, 0.07, 0.09),
    (1.15, 0.10, 0.05),
)
LONG_BROWN_FROM = 0.72

# 短く跳ね上がる皮。中ほどで一度下がってから、先端が上向きに反り返る。
FLAP_SPINE = (
    (0.10, 0.52, 0.11),
    (0.18, 0.39, 0.25),
    (0.27, 0.28, 0.34),
    (0.39, 0.20, 0.36),
    (0.52, 0.18, 0.34),
    (0.62, 0.23, 0.29),
    (0.69, 0.30, 0.22),
    (0.74, 0.38, 0.14),
    (0.78, 0.44, 0.07),
)
FLAP_BROWN_FROM = 0.80

# 立った胴体からヘタの先までの輪郭 (半径, 高さ)。円錐を積み重ねると
# 継ぎ目で陰影が割れるので、これを1本の回転体として作り、色だけ
# 高さで切り替える。
CORE_PROFILE = (
    (0.100, 0.02),
    (0.132, 0.08),
    (0.152, 0.20),
    (0.158, 0.32),
    (0.150, 0.45),
    (0.132, 0.55),
    (0.108, 0.62),
    (0.086, 0.67),
    (0.062, 0.71),
    (0.042, 0.745),
    (0.028, 0.775),
    (0.016, 0.80),
)
CORE_SEGMENTS = 20
# CORE_PROFILE の区間 index が、この境目から先は緑 / 茶になる。
CORE_GREEN_FROM = 6
CORE_BROWN_FROM = 9


def make_material(name, color, roughness=0.32, coat=0.25):
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    shader = next(
        node for node in material.node_tree.nodes
        if node.type == "BSDF_PRINCIPLED"
    )
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    if "Coat Weight" in shader.inputs:
        shader.inputs["Coat Weight"].default_value = coat
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

    (距離, 高さ, 幅) を各成分ごとに独立して補間する。端点は複製して
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
            resampled.append((point[0], point[1], max(point[2], 0.04)))
    resampled.append(spine[-1])
    return resampled


def arc_direction(index, span, normal, binormal):
    """断面の円弧上の向き。index=0 と ARC_SEG が樋の左右の縁、
    真ん中が樋の底（-normal 側）で、ここが皮の外側になる。"""
    a = -span * 0.5 + span * index / ARC_SEG
    return -normal * math.cos(a) + binormal * math.sin(a)


def arc_span_at(t):
    """先端側だけ開き角を絞る。"""
    if t <= TIP_CLOSE_FROM:
        return ARC_SPAN
    closing = (t - TIP_CLOSE_FROM) / (1.0 - TIP_CLOSE_FROM)
    return ARC_SPAN * (1.0 - (1.0 - TIP_CLOSE_SCALE) * closing)


def make_peel(name, angle_deg, spine, length_scale, roll_deg, materials, root,
              brown_from_ratio):
    """皮を1枚、C 字の樋の断面を背骨に沿って掃引した殻として作る。

    1リングあたり 外側円弧 (ARC_SEG+1 頂点) + 内側円弧 (ARC_SEG+1 頂点)。
    面は 外側 / 内側 / 左右のリム / 両端のふた の5種類で閉じる。
    brown_from_ratio (0-1) から先端側は表裏ともに茶色にする。
    """
    dense = resample_spine(spine, SPLINE_STEPS)
    ring_count = len(dense)
    brown_from = round((ring_count - 1) * brown_from_ratio)

    angle = math.radians(angle_deg)
    radial = Vector((math.cos(angle), math.sin(angle), 0.0))
    base_side = Vector((-math.sin(angle), math.cos(angle), 0.0))
    centers = [radial * (distance * length_scale) + Vector((0.0, 0.0, height))
               for distance, height, _width in dense]

    vertices = []
    for index, center in enumerate(centers):
        before = centers[max(index - 1, 0)]
        after = centers[min(index + 1, ring_count - 1)]
        tangent = (after - before).normalized()
        binormal = base_side.copy()
        normal = binormal.cross(tangent).normalized()
        if normal.z < 0.0:
            normal.negate()
            binormal.negate()
        t = index / (ring_count - 1)
        roll = math.radians(roll_deg[0] + (roll_deg[1] - roll_deg[0]) * t)
        if roll:
            twist = Matrix.Rotation(roll, 3, tangent)
            binormal = twist @ binormal
            normal = twist @ normal
        # 差し渡し width の弦を張る円弧の半径。
        span = arc_span_at(t)
        outer_radius = dense[index][2] / (2.0 * math.sin(span * 0.5))
        inner_radius = max(outer_radius - WALL, outer_radius * 0.45)
        for k in range(ARC_SEG + 1):
            vertices.append(center + arc_direction(k, span, normal, binormal)
                            * outer_radius)
        for k in range(ARC_SEG + 1):
            vertices.append(center + arc_direction(k, span, normal, binormal)
                            * inner_radius)

    stride = 2 * (ARC_SEG + 1)
    faces = []
    material_indices = []

    def outer(ring, k):
        return ring * stride + k

    def inner(ring, k):
        return ring * stride + (ARC_SEG + 1) + k

    for ring in range(ring_count - 1):
        brown = ring >= brown_from
        for k in range(ARC_SEG):
            # 外側（濃い黄）と内側（淡い黄）。巻き方向は後で
            # recalc_face_normals にそろえさせるので気にしない。
            faces.append((outer(ring, k), outer(ring, k + 1),
                          outer(ring + 1, k + 1), outer(ring + 1, k)))
            material_indices.append(2 if brown else 0)
            faces.append((inner(ring, k), inner(ring, k + 1),
                          inner(ring + 1, k + 1), inner(ring + 1, k)))
            material_indices.append(2 if brown else 1)
        # 皮の縁。厚みの分だけ立った細い帯なので外側と同じ色にする。
        for k in (0, ARC_SEG):
            faces.append((outer(ring, k), inner(ring, k),
                          inner(ring + 1, k), outer(ring + 1, k)))
            material_indices.append(2 if brown else 0)

    for k in range(ARC_SEG):
        faces.append((outer(0, k), outer(0, k + 1),
                      inner(0, k + 1), inner(0, k)))
        material_indices.append(0)
        last = ring_count - 1
        faces.append((outer(last, k), outer(last, k + 1),
                      inner(last, k + 1), inner(last, k)))
        material_indices.append(2)

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    for material in materials:
        mesh.materials.append(material)
    for polygon, material_index in zip(mesh.polygons, material_indices):
        polygon.material_index = material_index
    mesh.update()

    # 閉じた殻なので法線をまとめてそろえられる。そのうえで折れの強い稜線
    # （リムと両端のふたの境目）だけ切り離し、全面スムーズにしても
    # 皮の縁がぼやけないようにする。
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    sharp = [
        edge for edge in bm.edges
        if len(edge.link_faces) == 2
        and edge.link_faces[0].normal.length > 0.0
        and edge.link_faces[1].normal.length > 0.0
        and edge.link_faces[0].normal.angle(edge.link_faces[1].normal)
        > SHARP_ANGLE
    ]
    if sharp:
        bmesh.ops.split_edges(bm, edges=sharp)
    bm.to_mesh(mesh)
    bm.free()
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    return obj


def add_lathe(name, profile, segments, materials, root):
    """(半径, 高さ) の輪郭を Z 軸まわりに回した回転体。区間ごとに
    マテリアルを切り替えられるので、胴体〜ヘタ〜軸を1メッシュで作れる。"""
    vertices = []
    for radius, z in profile:
        for seg in range(segments):
            theta = 2.0 * math.pi * seg / segments
            vertices.append(Vector((radius * math.cos(theta),
                                    radius * math.sin(theta), z)))
    faces = []
    material_indices = []
    for ring in range(len(profile) - 1):
        if ring >= CORE_BROWN_FROM:
            material_index = 2
        elif ring >= CORE_GREEN_FROM:
            material_index = 1
        else:
            material_index = 0
        for seg in range(segments):
            following = (seg + 1) % segments
            faces.append((ring * segments + seg,
                          ring * segments + following,
                          (ring + 1) * segments + following,
                          (ring + 1) * segments + seg))
            material_indices.append(material_index)
    faces.append(tuple(reversed(range(segments))))
    material_indices.append(0)
    top = (len(profile) - 1) * segments
    faces.append(tuple(top + seg for seg in range(segments)))
    material_indices.append(2)

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    for material in materials:
        mesh.materials.append(material)
    for polygon, material_index in zip(mesh.polygons, material_indices):
        polygon.material_index = material_index
    for polygon in mesh.polygons[:-2]:
        polygon.use_smooth = True
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    return obj


def build():
    outer_material = make_material("BananaPeelOuter", PEEL_YELLOW,
                                   roughness=0.16, coat=0.65)
    inner_material = make_material("BananaPeelInner", INNER_YELLOW,
                                   roughness=0.42, coat=0.20)
    brown_material = make_material("BananaPeelTip", TIP_BROWN,
                                   roughness=0.55, coat=0.10)
    green_material = make_material("BananaPeelNeck", NECK_GREEN,
                                   roughness=0.50, coat=0.15)
    materials = (outer_material, inner_material, brown_material)

    root = bpy.data.objects.new("BananaPeel", None)
    bpy.context.collection.objects.link(root)

    # 参考画像の非対称なシルエット。長い皮2枚を手前の左右へ寝かせ、
    # 短い皮2枚を外向きに跳ね上げる。roll は樋の開口の向きで、
    # 跳ね上がる皮ほど強くひねって淡い内側の面を見せる。
    make_peel("PeelLongLeft", 200.0, LONG_SPINE, 1.0, (180.0, 148.0),
              materials, root, LONG_BROWN_FROM)
    make_peel("PeelLongRight", -22.0, LONG_SPINE, 0.92, (180.0, 212.0),
              materials, root, LONG_BROWN_FROM)
    make_peel("PeelFlapLeft", 122.0, FLAP_SPINE, 1.0, (180.0, 62.0),
              materials, root, FLAP_BROWN_FROM)
    make_peel("PeelFlapRight", 56.0, FLAP_SPINE, 0.88, (180.0, -56.0),
              materials, root, FLAP_BROWN_FROM)

    # 立った胴体と、その上のヘタ。上へ行くほど緑、先端は茶色。
    add_lathe("Core", CORE_PROFILE, CORE_SEGMENTS,
              (outer_material, green_material, brown_material), root)

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
    print("saved  :", BLEND_PATH)
    print("export :", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")


def render_previews(out_dir):
    """形の確認用プレビュー。"""
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.render_aa = '8'
    scene.render.resolution_x, scene.render.resolution_y = 760, 520
    scene.render.film_transparent = False

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    cam.data.lens = 45
    scene.camera = cam
    shots = [
        # 参考画像に近い、やや上からの正面
        ("front", (76, 0, 0), 0.28, 3.6),
        ("side", (90, 0, 90), 0.26, 3.6),
        ("top", (14, 0, 0), 0.18, 3.4),
        ("three", (62, 0, -38), 0.28, 3.4),
    ]
    for name, deg, target_z, dist in shots:
        euler = mathutils.Euler([math.radians(a) for a in deg], 'XYZ')
        cam.rotation_euler = euler
        cam.location = mathutils.Vector((0.0, 0.0, target_z)) + \
            euler.to_quaternion() @ mathutils.Vector((0.0, 0.0, dist))
        scene.render.filepath = os.path.join(out_dir, "banana_peel_%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("render :", scene.render.filepath)


def report(root):
    meshes = [child for child in root.children if child.type == "MESH"]
    radius = 0.0
    lowest = float("inf")
    highest = -float("inf")
    for child in meshes:
        for corner in child.bound_box:
            point = child.matrix_world @ Vector(corner)
            radius = max(radius, math.hypot(point.x, point.y))
            lowest = min(lowest, point.z)
            highest = max(highest, point.z)
    result = {
        "root": root.name,
        "objects": [child.name for child in root.children],
        "vertex_count": sum(len(child.data.vertices) for child in meshes),
        "polygon_count": sum(len(child.data.polygons) for child in meshes),
        "radius": round(radius, 3),
        "z_range": (round(lowest, 3), round(highest, 3)),
    }
    print(result)
    return result


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    clear_scene()
    root = build()
    export()
    report(root)
    if "--render" in argv:
        render_previews(argv[argv.index("--render") + 1])


main()
