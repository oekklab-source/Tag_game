"""？ブロック（アイテムボックス）を一から組み立てて glTF に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_item_box.py -- [--render <出力ディレクトリ>]

出力:
    tools/blender/item_box.blend      編集元（.gdignore で Godot のインポート対象外）
    assets/props/item_box.glb         Godot が読むモデル

これまで question_block は単色の BoxMesh + Label3D の「？」文字だけだった。
manhole.glb と同じくモデルを Blender 側で作り、「何が出るか分からない」を
単色ではなく側面ごとに違う原色パネルで表現する。「？」は Label3D のような
ビルボードにできない（glTF は常に正面を向けない）ので、側面4方向すべてに
金色の発光ジオメトリとして配置し、どの角度から見ても読めるようにしてある。

アニメーションは書き出さない。回転演出は manhole と同じく Godot 側の
_process() で毎フレーム rotate_y する（AnimationPlayer を増やさない）。
"""

import math
import os
import sys

import bmesh
import bpy

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "item_box.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "props", "item_box.glb")

# ---- 寸法（Blender は Z-up。単位はメートル。原点が箱の中心）----
# 既存の question_block.tscn の当たり判定（BoxShape3D 1.7m）に合わせる。
# シェルはわずかに小さくして、パネルの縁がはみ出さないようにする
BODY_SIZE = 1.6
BEVEL = 0.10        # 角の面取り量。角ばりすぎず、ただの球にもならない程度
PANEL_INSET = 0.30  # パネルが面より一回り小さく、暗い枠を覗かせる
PANEL_THICK = 0.05
PANEL_PAD = 0.06    # シェル面から浮かせる量。Z ファイティング防止

# ---- 配色 ----
# 「中身は分からない」を単色ではなく側面ごとに違う原色で表現する。
# 底面は常時見えないので塗らず、シェルの暗色のままにする
COLORS = {
    "Shell": (0.20, 0.20, 0.26),
    "PanelRed": (0.92, 0.18, 0.20),
    "PanelBlue": (0.16, 0.42, 0.94),
    "PanelGreen": (0.22, 0.78, 0.32),
    "PanelPurple": (0.62, 0.22, 0.86),
    "PanelYellow": (0.98, 0.80, 0.12),
    "MarkGold": (1.0, 0.86, 0.30),
}
# 「？」だけを他のどのパーツより強く光らせて、可読性を最優先にする
EMISSION = {
    "Shell": 0.0,
    "PanelRed": 0.18, "PanelBlue": 0.18, "PanelGreen": 0.18,
    "PanelPurple": 0.18, "PanelYellow": 0.18,
    "MarkGold": 1.6,
}
PANEL_COLORS = ["PanelRed", "PanelBlue", "PanelGreen", "PanelPurple", "PanelYellow"]


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

def build_shell():
    """角を面取りした暗色の箱。パネルの原色が引き立つよう地味な色にする。"""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=BODY_SIZE)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=BEVEL, segments=3, affect='EDGES')
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("Shell")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Shell", mesh)
    bpy.context.collection.objects.link(obj)
    for poly in mesh.polygons:
        poly.use_smooth = False
    return paint(obj, "Shell")


def build_body():
    """シェル＋側面5面（底面を除く）の原色パネルを1メッシュへ結合する。

    底面は地面に対して常に下向きで、フロートするアイテムボックスを
    見上げる形にはならないため塗らない（ポリゴンを増やすだけになる）。
    """
    half = BODY_SIZE / 2.0
    w = BODY_SIZE - PANEL_INSET
    panels = [
        paint(box("PanelX+", (PANEL_THICK, w, w), loc=(half + PANEL_PAD, 0, 0)), "PanelRed"),
        paint(box("PanelX-", (PANEL_THICK, w, w), loc=(-half - PANEL_PAD, 0, 0)), "PanelBlue"),
        paint(box("PanelY+", (w, PANEL_THICK, w), loc=(0, half + PANEL_PAD, 0)), "PanelGreen"),
        paint(box("PanelY-", (w, PANEL_THICK, w), loc=(0, -half - PANEL_PAD, 0)), "PanelPurple"),
        paint(box("PanelZ+", (w, w, PANEL_THICK), loc=(0, 0, half + PANEL_PAD)), "PanelYellow"),
    ]
    body = cleanup(join_into(build_shell(), panels))
    body.name = body.data.name = "Body"
    return body


def build_mark_glyph():
    """「？」1個を短い角柱の弧（フック5本＋点1個）で近似する。

    XZ 平面（Blender 上で見て正面）に構築し、厚みは Y 方向に薄く持たせる。
    build_mark() 側で 4方向へ回転コピーして側面に貼り付ける。
    """
    hook = [
        (0.00, 0.34, 15), (0.13, 0.30, -20), (0.19, 0.16, -60),
        (0.12, 0.03, -105), (-0.02, -0.02, -140),
    ]
    segs = [box("MarkSeg", (0.09, 0.045, 0.16), loc=(x, 0.0, z), rot=(0, math.radians(a), 0))
            for x, z, a in hook]
    segs.append(box("MarkDot", (0.11, 0.045, 0.11), loc=(-0.02, 0.0, -0.30)))
    return cleanup(join_into(segs[0], segs[1:]))


def build_mark():
    """「？」を箱の4側面（前後左右）すべてに配置する。

    Label3D と違って glTF はビルボードにできないため、どの向きから
    近づいても読めるよう側面4方向へ複製する（上面・底面は省略）。
    """
    half = BODY_SIZE / 2.0
    pad = 0.09
    placements = [
        (0.0, 0.0, 0.0, (0, half + pad, 0)),            # +Y 面
        (0.0, math.pi, 0.0, (0, -half - pad, 0)),        # -Y 面
        (0.0, math.pi / 2, 0.0, (half + pad, 0, 0)),     # +X 面
        (0.0, -math.pi / 2, 0.0, (-half - pad, 0, 0)),   # -X 面
    ]
    pieces = [bake(build_mark_glyph(), loc=loc, rot=(rx, ry, rz))
              for rx, ry, rz, loc in placements]
    mark = paint(cleanup(join_into(pieces[0], pieces[1:])), "MarkGold")
    mark.name = mark.data.name = "Mark"
    return mark


def build_sparkles():
    """箱の周りを舞う小さな結晶。5色を順番に割り当てて「サプライズ」を演出する。

    manhole の build_shards() と同じ黄金角スパイラル配置（結晶同士が
    同じ方位に重ならないようにする）を流用する。
    """
    count = 8
    parts = []
    for i in range(count):
        a = 2.4 * i
        radius = 0.95 + 0.10 * (i % 3)
        s = 0.09 + 0.02 * (i % 2)
        h = 0.15 * i - 0.5
        oct_profile = [(-s * 1.5, 0.0), (0.0, s), (s * 1.5, 0.0)]
        shard = lathe("Shard", oct_profile, 4, smooth=False)
        bake(shard, loc=(math.cos(a) * radius, math.sin(a) * radius, h), rot=(0.0, 0.0, a))
        parts.append(paint(shard, PANEL_COLORS[i % len(PANEL_COLORS)]))
    sparkles = cleanup(join_into(parts[0], parts[1:]))
    sparkles.name = sparkles.data.name = "Sparkles"
    return sparkles


# =====================================================================
# 組み立て
# =====================================================================

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear_scene()
    build_body()
    build_mark()
    build_sparkles()
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
        ("three_quarter", (68, 0, -35), 0.0, 3.4),
        ("front", (85, 0, 0), 0.0, 3.0),
        ("top", (10, 0, 0), 0.0, 3.2),
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
