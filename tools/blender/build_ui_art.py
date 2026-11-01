"""UI のロゴとアイコンを Blender で立体的に描いて PNG に書き出すビルドスクリプト。

    blender -b -P tools/blender/build_ui_art.py -- [--only 名前,名前] [--sheet <出力ディレクトリ>]

出力:
    ui/logo/reverse_tag_logo.png   タイトル画面のロゴ（文字「REVERSE TAG!」＋入れ替わる鬼と逃げる人）
    ui/logo/reverse_tag_mark.png   鬼と逃げる人が入れ替わる矢印だけのシンボル（アプリアイコン候補の元絵）
    ui/icons/<名前>.png         ボタンや HUD に載せる絵

UI は「読まなくても絵で分かる」ことを狙っているので、どの絵も
  * 太い丸みのある立体（おもちゃのプラスチック）
  * 濃い紫の太いふち取り＋外側の白いふち（明るい背景でも 3D の画面の上でも沈まない）
で統一する。ふち取りはレンダリング後に numpy でアルファを膨らませて付ける
（コンポジターの API は Blender 5.x で変わっていて、版をまたぐと壊れやすいため）。

キャラは tools/blender/fallguy.blend から読み込む（ゲーム内と同じ形・同じポーズになる）。
ロゴの文字は同梱フォント ui/fonts/MPLUSRounded1c-Bold.ttf（OFL）を使う。

--sheet を付けると、全部を並べた一覧画像 ui_art_sheet.png をそのディレクトリへ出す
（128px に縮めても、明るい背景でも暗い背景でも形が分かるかを見るため）。

--app-icon を付けると、シンボルからアプリアイコンの候補を docs/concept/store/app_icon/ へ出す
（1024 / 256 / 16 の3枚。16px でも判別できるかを見るため。ゲームへの組み込みはしない）。
"""

import math
import os
import sys
import tempfile

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICON_DIR = os.path.join(PROJECT, "ui", "icons")
LOGO_DIR = os.path.join(PROJECT, "ui", "logo")
FONT_PATH = os.path.join(PROJECT, "ui", "fonts", "MPLUSRounded1c-Bold.ttf")
BEAN_BLEND = os.path.join(PROJECT, "tools", "blender", "fallguy.blend")

# ---- 配色（sRGB の 16 進。UI のテーマ ui/pop_theme.tres と揃える）----
PINK = "#ff4fa3"
YELLOW = "#ffd23f"
CYAN = "#3ec8f5"
PURPLE = "#3b1d6e"     # ふち・影
VIOLET = "#8b5cf6"
WHITE = "#ffffff"
ORANGE = "#ff8a3d"
GREY = "#b9c2d6"
DARK = "#4a4f6a"
RUNNER = "#4ade80"     # 逃げる人（緑）。icon.svg 以来の記号
HUNTER = "#ef4444"     # 鬼（赤）

# 仕上がりの何倍で描くか。ふち取りを膨らませてから縮めると輪郭がなめらかになる
SUPERSAMPLE = 2
# ふちの太さ（仕上がりの一辺に対する割合）
OUTLINE = 0.030        # 濃い紫
RIM = 0.014            # その外側の白
DROP = 0.022           # 紫のふちを下へずらして重ねる量（分厚い板に見せる）
# 絵の周りに残す余白。ふち・白・下の厚みがはみ出さないぶん
PAD = OUTLINE + RIM + DROP + 0.02


# =====================================================================
# シーン
# =====================================================================

def srgb(hex_color):
    """16 進の sRGB をリニアへ。マテリアルの色はリニアで、View Transform が
    Standard なら書き出した PNG がちょうど元の 16 進の色になる。"""
    h = hex_color.lstrip("#")
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255.0
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    # エンジンの識別子は版で変わる（4.2〜4.5 は BLENDER_EEVEE_NEXT）。だめなら既存の
    # ビルドスクリプトと同じ Workbench に落とす
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT", "BLENDER_WORKBENCH"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if scene.render.engine == "BLENDER_WORKBENCH":
        scene.display.shading.light = "STUDIO"
        scene.display.shading.color_type = "MATERIAL"
        scene.display.render_aa = "8"
    else:
        scene.eevee.taa_render_samples = 32
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    # 既定の AgX は彩度を大きく落とすので、配色を決めた色がそのまま出る Standard にする
    # （build_boost_panel.py と同じ理由）
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs[0].default_value = (1.0, 1.0, 1.0, 1.0)
    bg.inputs[1].default_value = 0.55
    scene.world = world

    # 左上手前からの主光と、右手前からの弱い補助光（影を落とさない）
    for name, energy, rot, shadow in (
            ("Key", 3.2, (50, 0, -35), True),
            ("Fill", 1.1, (70, 0, 55), False)):
        light = bpy.data.lights.new(name, "SUN")
        light.energy = energy
        light.use_shadow = shadow
        obj = bpy.data.objects.new(name, light)
        obj.rotation_euler = Euler([math.radians(a) for a in rot], "XYZ")
        scene.collection.objects.link(obj)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    _MATS.clear()


_MATS = {}


def mat(hex_color, rough=0.32, emit=0.22):
    """つやのあるプラスチック。少し自己発光させて影の側も色を保つ。"""
    key = (hex_color, rough, emit)
    if key in _MATS:
        return _MATS[key]
    m = bpy.data.materials.new("M_" + hex_color)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    rgb = srgb(hex_color)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = emit
    m.diffuse_color = (*rgb, 1.0)
    _MATS[key] = m
    return m


# =====================================================================
# 形の部品（絵は -Y 側から見る。X が右、Z が上）
# =====================================================================

def _link(name, mesh, material, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    for poly in mesh.polygons:
        poly.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    obj.location = loc
    obj.rotation_euler = Euler([math.radians(a) for a in rot], "XYZ")
    obj.scale = scale
    if material:
        mesh.materials.append(material)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _bevel(obj, width, segments=4):
    if width <= 0.0:
        return
    mod = obj.modifiers.new("Bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(40)
    mod.harden_normals = True


def prism(pts, depth, material, bevel=0.05, **kw):
    """XZ 平面の多角形を Y 方向に押し出した板。矢印・星・稲妻など平たい絵文字の基本形。"""
    bm = bmesh.new()
    front = [bm.verts.new((x, -depth / 2.0, z)) for x, z in pts]
    back = [bm.verts.new((x, depth / 2.0, z)) for x, z in pts]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[j], front[i], back[i], back[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("Prism")
    bm.to_mesh(mesh)
    bm.free()
    obj = _link("Prism", mesh, material, **kw)
    _bevel(obj, bevel)
    return obj


def box(size, material, bevel=0.08, **kw):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    mesh = bpy.data.meshes.new("Box")
    bm.to_mesh(mesh)
    bm.free()
    obj = _link("Box", mesh, material, **kw)
    _bevel(obj, bevel)
    return obj


def cyl(radius, depth, material, bevel=0.05, axis="Y", radius2=None, segments=48, **kw):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius,
                          radius2=radius if radius2 is None else radius2, depth=depth)
    if axis == "Y":
        bmesh.ops.rotate(bm, cent=(0, 0, 0), verts=bm.verts,
                         matrix=Matrix.Rotation(math.radians(90), 3, "X"))
    mesh = bpy.data.meshes.new("Cyl")
    bm.to_mesh(mesh)
    bm.free()
    obj = _link("Cyl", mesh, material, **kw)
    _bevel(obj, bevel)
    return obj


def ball(radius, material, **kw):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=40, v_segments=20, radius=radius)
    mesh = bpy.data.meshes.new("Ball")
    bm.to_mesh(mesh)
    bm.free()
    return _link("Ball", mesh, material, **kw)


def tube(pts, radius, material, cyclic=False, **kw):
    """点列をなぞる丸い管。取っ手・弧・輪に使う。"""
    curve = bpy.data.curves.new("Tube", "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 6
    curve.use_fill_caps = True
    spline = curve.splines.new("POLY")
    spline.points.add(len(pts) - 1)
    for point, p in zip(spline.points, pts):
        point.co = (p[0], p[1], p[2], 1.0)
    spline.use_cyclic_u = cyclic
    obj = bpy.data.objects.new("Tube", curve)
    obj.location = kw.get("loc", (0, 0, 0))
    obj.rotation_euler = Euler([math.radians(a) for a in kw.get("rot", (0, 0, 0))], "XYZ")
    curve.materials.append(material)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def lathe(profile, material, **kw):
    """(半径, 高さ) の並びを Z 軸まわりに回した回転体。"""
    mesh = bpy.data.meshes.new("Lathe")
    verts = [(r, 0.0, z) for r, z in profile]
    edges = [(i, i + 1) for i in range(len(profile) - 1)]
    mesh.from_pydata(verts, edges, [])
    obj = _link("Lathe", mesh, material, **kw)
    screw = obj.modifiers.new("Screw", "SCREW")
    screw.axis = "Z"
    screw.steps = screw.render_steps = 48
    screw.use_smooth_shade = True
    screw.use_normal_calculate = True
    screw.use_merge_vertices = True
    # 輪郭の角まで滑らかに塗るとのっぺりするので、角のところで面を割る
    split = obj.modifiers.new("Split", "EDGE_SPLIT")
    split.split_angle = math.radians(35)
    return obj


def arc(cx, cz, radius, a0, a1, n=24, y=0.0):
    """XZ 平面の円弧の点列（角度は度。0 が右、90 が上）。"""
    out = []
    for i in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * i / n)
        out.append((cx + radius * math.cos(a), y, cz + radius * math.sin(a)))
    return out


def star_pts(outer, inner, points=5, rot=90.0):
    out = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        a = math.radians(rot + 180.0 * i / points)
        out.append((r * math.cos(a), r * math.sin(a)))
    return out


def letter(ch, size, face_hex, side_hex, depth=0.22, **kw):
    """立体の1文字。正面と側面で色を変えるためにメッシュへ変換して法線で塗り分ける。"""
    curve = bpy.data.curves.new("Glyph", "FONT")
    curve.body = ch
    curve.font = bpy.data.fonts.load(FONT_PATH, check_existing=True)
    curve.size = size
    curve.extrude = depth
    curve.bevel_depth = size * 0.035
    curve.bevel_resolution = 3
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    tmp = bpy.data.objects.new("GlyphTmp", curve)
    bpy.context.scene.collection.objects.link(tmp)
    # テキストは XY 平面に寝ているので、立てて -Y を正面にする
    tmp.rotation_euler = Euler((math.radians(90), 0, 0), "XYZ")
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
    bpy.data.objects.remove(tmp)
    mesh.transform(Matrix.Rotation(math.radians(90), 4, "X"))
    mesh.materials.append(mat(face_hex))
    mesh.materials.append(mat(side_hex))
    for poly in mesh.polygons:
        poly.material_index = 0 if poly.normal.y < -0.5 else 1
    return _link("Glyph_" + ch, mesh, None, **kw)


def bean(body_hex, clip, frame, loc=(0, 0, 0), yaw=0.0, tilt=(0.0, 0.0), scale=1.0):
    """ゲームのキャラ（きょうりゅう）を指定のアニメの1コマで立たせる。

    読み込むたびにデータが複製されるので、体の色は個体ごとに独立して変えられる。
    yaw は 0 で正面（こちら向き）、正で画面の右を向く。tilt は (前傾, 横倒し) の度数で、
    Dive はゲーム側が親ノードを約 69 度前へ倒して使うアニメなので、同じだけ倒して使う。
    """
    with bpy.data.libraries.load(BEAN_BLEND, link=False) as (src, dst):
        dst.objects = list(src.objects)
    rig = None
    for obj in dst.objects:
        bpy.context.scene.collection.objects.link(obj)
        if obj.type == "ARMATURE":
            rig = obj
    for obj in dst.objects:
        if obj.type != "MESH":
            continue
        for slot in obj.material_slots:
            if slot.material and slot.material.name.split(".")[0] == "Body":
                rgb = srgb(body_hex)
                bsdf = next(n for n in slot.material.node_tree.nodes
                            if n.type == "BSDF_PRINCIPLED")
                bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
                bsdf.inputs["Roughness"].default_value = 0.32
                bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
                bsdf.inputs["Emission Strength"].default_value = 0.22
    anim = rig.animation_data
    # NLA は全トラックが重なって評価されるので、使う1本以外を黙らせてから直接アクションを当てる
    strip = anim.nla_tracks[clip].strips[0]
    for track in anim.nla_tracks:
        track.mute = True
    anim.action = strip.action
    try:
        anim.action_slot = strip.action_slot or strip.action.slots[0]
    except (AttributeError, IndexError):
        pass
    rig.location = loc
    rig.rotation_euler = Euler((math.radians(tilt[0]), math.radians(tilt[1]),
                                math.radians(yaw)), "XYZ")
    rig.scale = (scale, scale, scale)
    # シーンのフレームは全キャラ共通。このコマの姿勢をボーンに残したままアクションを外し、
    # 次のキャラが別のコマを指定しても動かないようにする
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    anim.action = None
    return rig


# =====================================================================
# 撮影と仕上げ
# =====================================================================

def _fit_camera(width, height, yaw, pitch):
    """絵の全体がちょうど収まるように平行投影カメラを合わせる。"""
    scene = bpy.context.scene
    cam = scene.camera
    cam.rotation_euler = Euler((math.radians(90.0 - pitch), 0.0, math.radians(yaw)), "XYZ")
    bpy.context.view_layer.update()
    basis = cam.rotation_euler.to_matrix()
    right, up, back = basis.col[0], basis.col[1], basis.col[2]
    dg = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in scene.objects:
        if obj.type not in {"MESH", "CURVE", "FONT"} or obj.hide_render:
            continue
        ev = obj.evaluated_get(dg)
        mesh = ev.to_mesh()
        for v in mesh.vertices:
            w = ev.matrix_world @ v.co
            p = Vector((w.dot(right), w.dot(up), w.dot(back)))
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
        ev.to_mesh_clear()
    w, h = hi.x - lo.x, hi.y - lo.y
    grow = 1.0 / (1.0 - 2.0 * PAD)
    if width >= height:
        cam.data.ortho_scale = max(w, h * width / height) * grow
    else:
        cam.data.ortho_scale = max(h, w * height / width) * grow
    center = right * ((lo.x + hi.x) / 2.0) + up * ((lo.y + hi.y) / 2.0)
    cam.location = center + back * (hi.z + 20.0)
    cam.data.clip_start = 0.1
    cam.data.clip_end = (hi.z - lo.z) + 60.0


def _dilate(alpha, radius):
    """アルファを円形に膨らませる（円の中のずらした像の最大値）。"""
    r = int(math.ceil(radius))
    out = alpha.copy()
    h, w = alpha.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > radius * radius or (dx == 0 and dy == 0):
                continue
            ys, yd = (slice(dy, h), slice(0, h - dy)) if dy >= 0 else (slice(0, h + dy), slice(-dy, h))
            xs, xd = (slice(dx, w), slice(0, w - dx)) if dx >= 0 else (slice(0, w + dx), slice(-dx, w))
            np.maximum(out[yd, xd], alpha[ys, xs], out=out[yd, xd])
    return out


def _over(dst_rgb, dst_a, src_rgb, src_a):
    """src を dst の上に重ねる（非乗算アルファ）。"""
    a = src_a + dst_a * (1.0 - src_a)
    safe = np.where(a > 1e-6, a, 1.0)
    rgb = (src_rgb * src_a[..., None] + dst_rgb * (dst_a * (1.0 - src_a))[..., None]) / safe[..., None]
    return rgb, a


def _load_pixels(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


def _save_pixels(path, px):
    h, w = px.shape[:2]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img = bpy.data.images.new("Out", w, h, alpha=True)
    img.alpha_mode = "STRAIGHT"
    img.pixels.foreach_set(np.ascontiguousarray(px, dtype=np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def _hex_rgb(hex_color):
    h = hex_color.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def shoot(path, width, height=None, yaw=-16.0, pitch=10.0, trim=False):
    """撮って、ふち取りを付けて、仕上がりの大きさへ縮めて保存する。"""
    height = height or width
    scene = bpy.context.scene
    scene.render.resolution_x = width * SUPERSAMPLE
    scene.render.resolution_y = height * SUPERSAMPLE
    scene.render.resolution_percentage = 100
    _fit_camera(width, height, yaw, pitch)
    tmp = os.path.join(tempfile.gettempdir(), "ui_art_raw.png")
    scene.render.filepath = tmp
    bpy.ops.render.render(write_still=True)

    px = _load_pixels(tmp)
    rgb, alpha = px[..., :3], px[..., 3]
    unit = min(width, height) * SUPERSAMPLE
    ink = _dilate(alpha, OUTLINE * unit)
    # 画像の行は下から上へ並ぶので、下へずらす＝添字の小さい方へずらす
    drop = int(round(DROP * unit))
    lowered = np.zeros_like(ink)
    lowered[:-drop, :] = ink[drop:, :]
    ink = np.maximum(ink, lowered)
    rim = _dilate(ink, RIM * unit)

    out_rgb = np.broadcast_to(_hex_rgb(WHITE), rgb.shape).copy()
    out_a = rim
    out_rgb, out_a = _over(out_rgb, out_a, np.broadcast_to(_hex_rgb(PURPLE), rgb.shape), ink)
    out_rgb, out_a = _over(out_rgb, out_a, rgb, alpha)
    out = np.dstack([out_rgb, out_a])

    s = SUPERSAMPLE
    h2, w2 = out.shape[0] // s, out.shape[1] // s
    # 縮めるときは色をアルファで重み付けする（透明な画素の色が輪郭ににじまないように）
    blocks = out[:h2 * s, :w2 * s].reshape(h2, s, w2, s, 4)
    a = blocks[..., 3]
    a_mean = a.mean(axis=(1, 3))
    c_sum = (blocks[..., :3] * a[..., None]).sum(axis=(1, 3))
    c = c_sum / np.maximum(a.sum(axis=(1, 3)), 1e-6)[..., None]
    small = np.dstack([c, a_mean])

    if trim:
        ys, xs = np.nonzero(small[..., 3] > 0.004)
        small = small[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    _save_pixels(path, small)
    print("render :", path, small.shape[1], "x", small.shape[0])


# =====================================================================
# ロゴ
# =====================================================================

def _word(text, size, face_hex, side_hex, z, tilt_seq, gap=0.06):
    """1行ぶんの文字を、1字ずつ少し傾けて弾んだ感じに並べる。行の幅を返す。"""
    objs = []
    for i, ch in enumerate(text):
        obj = letter(ch, size, face_hex, side_hex)
        objs.append(obj)
    bpy.context.view_layer.update()
    widths = [o.dimensions.x for o in objs]
    total = sum(widths) + gap * size * (len(objs) - 1)
    x = -total / 2.0
    for i, (obj, w) in enumerate(zip(objs, widths)):
        tilt = tilt_seq[i % len(tilt_seq)]
        obj.location = (x + w / 2.0, 0.0, z + 0.05 * size * math.sin(i * 2.1))
        obj.rotation_euler = Euler((0.0, math.radians(tilt), 0.0), "XYZ")
        x += w + gap * size
    return total


def swap_arrows(cx, cz, r, rad=0.17, span=140, y=-0.1, arcs=((25, HUNTER), (205, RUNNER))):
    """役割の入れ替わりを示す弧の矢印。赤は鬼、緑は逃げる人の色。arcs は (開始角, 色) の並びで、
    span が負なら時計回り。太い管と大きめの矢じりにして、小さく縮めても矢印だと分かるようにする。"""
    for a0, color in arcs:
        a1 = a0 + span
        tube(arc(cx, cz, r, a0, a1, n=28, y=y), rad, mat(color))
        e = math.radians(a1)
        # 矢じりは進行方向（反時計回りなら接線の向き、時計回りなら逆）へ向ける
        turn = -a1 if span > 0 else 180.0 - a1
        prism([(0.0, rad * 2.8), (-rad * 2.2, -rad * 1.1), (rad * 2.2, -rad * 1.1)], rad * 2.2,
              mat(color), bevel=0.05,
              loc=(cx + r * math.cos(e), y, cz + r * math.sin(e)), rot=(0, turn, 0))


def build_logo():
    """上段「REVERSE」、下段に大きく「TAG!」。鬼ごっこ（TAG）の役割が逆転する、という意味。

    下段の文字の左に飛びつく鬼、右に逃げる人を置く。上段は下段より短く、左右の肩に空きが
    できるので、そこへ入れ替わりの弧の矢印を置く（赤が鬼から、緑が逃げる人から、互いへ向かう）。
    キャラは文字に被らないよう、下段の文字の外側に立たせる。
    """
    top = _word("REVERSE", 1.45, "#ff5a5a", "#b3202c", 2.4, (-6, 5, -4, 6, -5, 4, -6))
    bottom = _word("TAG!", 2.7, YELLOW, ORANGE, 0.0, (-5, 6, -4, 5))
    side = bottom / 2.0
    bean(HUNTER, "Dive", 22, loc=(-side - 2.0, 0.3, -0.6), yaw=52, tilt=(48, 0), scale=1.5)
    bean(RUNNER, "Run", 6, loc=(side + 1.2, 0.3, -0.75), yaw=38, scale=1.5)
    wing = top / 2.0 + 0.7
    swap_arrows(-wing - 0.95, 1.9, 0.85, rad=0.21, span=-130, arcs=((170, HUNTER),))
    swap_arrows(wing + 0.95, 1.9, 0.85, rad=0.21, span=130, arcs=((10, RUNNER),))


def build_mark():
    """入れ替わる鬼と逃げる人。文字が無くても何のゲームか伝わる最小の絵。"""
    bean(HUNTER, "Dive", 22, loc=(-1.55, 0.6, -0.6), yaw=52, tilt=(48, 0))
    bean(RUNNER, "Run", 6, loc=(1.35, -0.2, -0.8), yaw=38)
    swap_arrows(0.0, 1.45, 1.0, arcs=((25, HUNTER), (205, RUNNER)))


# =====================================================================
# アイコン
# =====================================================================

def build_play():
    """あそぶ（オンライン）: 鬼が逃げる人を追う＝このゲームそのもの。上の電波で通信対戦を示す。"""
    bean(HUNTER, "Run", 18, loc=(-0.85, 0.3, 0.0), yaw=38)
    bean(RUNNER, "Run", 6, loc=(0.85, -0.3, 0.0), yaw=38)
    for r in (0.3, 0.56, 0.82):
        tube(arc(0.0, 1.85, r, 40, 140), 0.095, mat(CYAN))
    ball(0.15, mat(CYAN), loc=(0.0, 0.0, 1.85))


def build_solo():
    """ソロ: 自分ひとり対ロボット（CPU）。"""
    bean(RUNNER, "Nice", 9, loc=(-0.85, 0.0, 0.0), yaw=14)
    # ロボの鬼: 四角い頭にアンテナと目
    box((1.15, 0.9, 0.95), mat(GREY), bevel=0.16, loc=(0.95, 0.0, 0.95))
    box((0.85, 0.7, 0.55), mat(DARK), bevel=0.12, loc=(0.95, 0.0, 0.28))
    box((0.8, 0.1, 0.32), mat(PURPLE), bevel=0.04, loc=(0.95, -0.46, 1.0))
    ball(0.1, mat(HUNTER, emit=1.2), loc=(0.72, -0.5, 1.0))
    ball(0.1, mat(HUNTER, emit=1.2), loc=(1.18, -0.5, 1.0))
    cyl(0.045, 0.34, mat(DARK), axis="Z", bevel=0.0, loc=(0.95, 0.0, 1.58))
    ball(0.13, mat(HUNTER), loc=(0.95, 0.0, 1.8))


def build_costume():
    """きせかえ: T シャツ。"""
    shirt = [(-0.42, 0.95), (-0.2, 1.0), (0.0, 0.84), (0.2, 1.0), (0.42, 0.95),
             (1.05, 0.52), (0.78, 0.08), (0.52, 0.24), (0.52, -0.95),
             (-0.52, -0.95), (-0.52, 0.24), (-0.78, 0.08), (-1.05, 0.52)]
    prism(shirt, 0.34, mat(PINK), bevel=0.09)
    prism(star_pts(0.3, 0.13), 0.14, mat(YELLOW), bevel=0.03, loc=(0.0, -0.2, -0.1))


def build_shop():
    """ショップ: 買い物袋と宝石。"""
    box((1.5, 0.7, 1.45), mat(YELLOW), bevel=0.14, loc=(0.0, 0.0, 0.0))
    tube(arc(0.0, 0.7, 0.36, 0, 180, y=-0.2), 0.07, mat(PURPLE))
    tube(arc(0.0, 0.7, 0.36, 0, 180, y=0.2), 0.07, mat(PURPLE))
    gem = cyl(0.36, 0.3, mat(CYAN, rough=0.12, emit=0.35), bevel=0.0, segments=6,
              radius2=0.2, loc=(0.0, -0.44, -0.1), rot=(0, 30, 0))
    gem.data.polygons.foreach_set("use_smooth", [False] * len(gem.data.polygons))


def build_friends():
    """フレンド: 並んで喜ぶふたり。"""
    bean(CYAN, "Nice", 9, loc=(-0.72, 0.0, 0.0), yaw=12)
    bean(PINK, "Nice", 27, loc=(0.72, 0.0, 0.0), yaw=-12)


def build_ranking():
    """ランキング: トロフィー。"""
    gold = mat(YELLOW, rough=0.2, emit=0.25)
    lathe([(0.0, 0.0), (0.55, 0.0), (0.55, 0.16), (0.2, 0.26), (0.13, 0.62),
           (0.3, 0.74), (0.62, 1.08), (0.72, 1.62), (0.6, 1.62), (0.0, 1.5)], gold)
    for sx in (-1, 1):
        tube([(sx * x, 0.0, z) for x, _, z in arc(0.66, 1.3, 0.3, -70, 80)], 0.07, gold)
    prism(star_pts(0.26, 0.11), 0.12, mat(WHITE, emit=0.5), bevel=0.02, loc=(0.0, -0.62, 1.3))


def build_settings():
    """設定: 歯車。"""
    teeth, pts = 8, []
    for i in range(teeth):
        base = 360.0 * i / teeth
        for da, r in ((-13, 0.74), (-8, 1.0), (8, 1.0), (13, 0.74)):
            a = math.radians(base + da)
            pts.append((r * math.cos(a), r * math.sin(a)))
    gear = prism(pts, 0.38, mat("#8fa0c4", emit=0.1), bevel=0.0)
    hole = cyl(0.33, 1.0, None, bevel=0.0)
    hole.hide_render = True
    hole.display_type = "WIRE"
    cut = gear.modifiers.new("Hole", "BOOLEAN")
    cut.operation = "DIFFERENCE"
    cut.object = hole
    _bevel(gear, 0.06)


def build_quit():
    """終了: 出口の扉と、外へ向かう矢印。"""
    frame = [(-0.75, 1.0), (0.45, 1.0), (0.45, -1.0), (-0.75, -1.0), (-0.75, -0.72),
             (0.17, -0.72), (0.17, 0.72), (-0.75, 0.72)]
    prism(frame, 0.4, mat(VIOLET), bevel=0.07)
    arrow = [(-0.75, 0.17), (0.25, 0.17), (0.25, 0.48), (0.95, 0.0), (0.25, -0.48),
             (0.25, -0.17), (-0.75, -0.17)]
    prism(arrow, 0.3, mat(HUNTER), bevel=0.07, loc=(0.35, -0.3, 0.0))


# ---------------------------------------------------------------------
# 共通の操作（どの画面でも同じ絵を使う）
# ---------------------------------------------------------------------

def build_ok():
    """決定・保存: チェック。"""
    prism([(-0.95, 0.0), (-0.58, 0.38), (-0.22, 0.02), (0.6, 0.86), (0.95, 0.5), (-0.22, -0.72)],
          0.4, mat(RUNNER), bevel=0.1)


def build_cancel():
    """やめる・閉じる・退出させる: バツ。"""
    for angle in (45, -45):
        box((2.3, 0.4, 0.5), mat(HUNTER), bevel=0.12, rot=(0, angle, 0))


def _arrow(material, flip=1.0, **kw):
    pts = [(-0.95, 0.24), (0.1, 0.24), (0.1, 0.66), (0.95, 0.0), (0.1, -0.66),
           (0.1, -0.24), (-0.95, -0.24)]
    return prism([(x * flip, z) for x, z in pts], 0.4, material, bevel=0.1, **kw)


def build_back():
    """もどる: 左向きの矢印。"""
    _arrow(mat(PINK), flip=-1.0)


def build_refresh():
    """更新・やり直し: 回る矢印。"""
    tube(arc(0.0, 0.0, 0.72, 40, 320, n=40), 0.15, mat(CYAN))
    prism([(0.0, 0.42), (-0.4, -0.22), (0.4, -0.22)], 0.36, mat(CYAN), bevel=0.06,
          loc=(0.72 * math.cos(math.radians(320)), 0.0, 0.72 * math.sin(math.radians(320))),
          rot=(0, 40, 0))


def build_plus():
    """作る・足す: プラス。"""
    box((2.0, 0.4, 0.56), mat(RUNNER), bevel=0.12)
    box((0.56, 0.42, 2.0), mat(RUNNER), bevel=0.12)


def build_search():
    """さがす: 虫めがね。"""
    tube(arc(-0.2, 0.25, 0.62, 0, 360, n=40), 0.14, mat(VIOLET), cyclic=True)
    cyl(0.55, 0.12, mat("#bfeaff", rough=0.1, emit=0.5), bevel=0.0, loc=(-0.2, 0.0, 0.25))
    box((0.3, 0.3, 0.95), mat(VIOLET), bevel=0.1, loc=(0.52, 0.0, -0.55), rot=(0, 135, 0))


def build_stop():
    """中断: 四角い停止ボタン。"""
    box((1.5, 0.45, 1.5), mat(HUNTER), bevel=0.2)


def build_link():
    """招待リンクをコピー: 鎖。"""
    for dx, dz, color in ((-0.38, -0.3, CYAN), (0.38, 0.3, VIOLET)):
        ring = [(0.62 * math.cos(math.radians(a)), 0.0, 0.34 * math.sin(math.radians(a)))
                for a in range(0, 360, 9)]
        tube(ring, 0.13, mat(color), cyclic=True, loc=(dx, 0.0, dz), rot=(0, -38, 0))


def build_gem():
    """ジェム（ゲーム内通貨）。"""
    gem_mat = mat(CYAN, rough=0.1, emit=0.35)
    top = cyl(0.85, 0.36, gem_mat, bevel=0.0, axis="Z", radius2=0.5, segments=8, loc=(0, 0, 0.5))
    bottom = cyl(0.0, 1.0, gem_mat, bevel=0.0, axis="Z", radius2=0.85, segments=8, loc=(0, 0, -0.18))
    for obj in (top, bottom):
        obj.data.polygons.foreach_set("use_smooth", [False] * len(obj.data.polygons))
        obj.rotation_euler = Euler((0, 0, math.radians(22.5)), "XYZ")


def build_lock():
    """まだ使えない・動けない: 南京錠。"""
    tube(arc(0.0, 0.3, 0.42, 0, 180), 0.13, mat(GREY, emit=0.1))
    box((1.35, 0.55, 1.1), mat(YELLOW), bevel=0.16, loc=(0, 0, -0.35))
    cyl(0.15, 0.2, mat(PURPLE), bevel=0.0, loc=(0, -0.26, -0.28))
    box((0.12, 0.2, 0.34), mat(PURPLE), bevel=0.03, loc=(0, -0.26, -0.5))


def build_gift():
    """アイテム・プレゼント: リボンの箱（ゲーム内の ? ブロックと同じ見た目の系統）。"""
    box((1.4, 1.4, 1.0), mat("#e0314b"), bevel=0.1, loc=(0, 0, -0.3))
    box((1.56, 1.56, 0.34), mat("#f04a62"), bevel=0.08, loc=(0, 0, 0.34))
    cream = mat("#fff0cf")
    box((0.3, 1.6, 1.74), cream, bevel=0.03, loc=(0, 0, 0.0))
    box((1.6, 0.3, 1.74), cream, bevel=0.03, loc=(0, 0, 0.0))
    for sx in (-1, 1):
        ball(0.26, cream, loc=(sx * 0.24, 0, 0.72), scale=(1.0, 0.6, 0.7), rot=(0, sx * 25, 0))


def build_fullscreen():
    """全画面: 四隅の角。"""
    corner = [(0.3, 0.98), (0.98, 0.98), (0.98, 0.3), (0.66, 0.3), (0.66, 0.66), (0.3, 0.66)]
    for sx in (-1, 1):
        for sz in (-1, 1):
            prism([(x * sx, z * sz) for x, z in corner], 0.36, mat(VIOLET), bevel=0.08)


# ---------------------------------------------------------------------
# 役割・ロビー
# ---------------------------------------------------------------------

def _horns(rig):
    """鬼の角。キャラの子にするので、向きを変えても頭の上に付いてくる。"""
    for sx in (-1, 1):
        horn = cyl(0.13, 0.42, mat(YELLOW), bevel=0.0, axis="Z", radius2=0.0, segments=20,
                   loc=(sx * 0.2, 0.0, 1.66), rot=(0, sx * 14, 0))
        horn.parent = rig


def build_role_runner():
    """逃げる人（緑）。"""
    bean(RUNNER, "Run", 6, yaw=38)


def build_role_hunter():
    """鬼（赤・角つき）。"""
    _horns(bean(HUNTER, "Idle", 0, yaw=16))


def _robot(loc=(0.0, 0.0, 0.0)):
    x, y, z = loc
    box((1.15, 0.9, 0.95), mat(GREY), bevel=0.16, loc=(x, y, z + 0.95))
    box((0.85, 0.7, 0.55), mat(DARK), bevel=0.12, loc=(x, y, z + 0.28))
    box((0.8, 0.1, 0.32), mat(PURPLE), bevel=0.04, loc=(x, y - 0.46, z + 1.0))
    for sx in (-1, 1):
        ball(0.1, mat(HUNTER, emit=1.2), loc=(x + sx * 0.23, y - 0.5, z + 1.0))
    cyl(0.045, 0.34, mat(DARK), axis="Z", bevel=0.0, loc=(x, y, z + 1.58))
    ball(0.13, mat(HUNTER), loc=(x, y, z + 1.8))


def build_cpu():
    """CPU（ロボット）。"""
    _robot()


def build_crown():
    """ホスト: 王冠。"""
    prism([(-0.95, -0.55), (0.95, -0.55), (0.95, 0.5), (0.48, 0.0), (0.0, 0.7), (-0.48, 0.0),
           (-0.95, 0.5)], 0.4, mat(YELLOW), bevel=0.08)
    for x, z, color in ((-0.95, 0.56, PINK), (0.0, 0.76, CYAN), (0.95, 0.56, PINK)):
        ball(0.16, mat(color), loc=(x, 0, z))


def build_hourglass():
    """待っている: 砂時計。"""
    lathe([(0.0, -0.78), (0.62, -0.78), (0.1, 0.0), (0.62, 0.78), (0.0, 0.78)],
          mat("#bfeaff", rough=0.1, emit=0.4))
    lathe([(0.0, -0.76), (0.5, -0.76), (0.12, -0.25), (0.0, -0.25)], mat(YELLOW), loc=(0, 0, 0.0))
    for z in (-0.88, 0.88):
        cyl(0.78, 0.2, mat(VIOLET), bevel=0.06, axis="Z", loc=(0, 0, z))


def build_start():
    """はじめる: 再生の三角。"""
    prism([(-0.62, 0.9), (0.9, 0.0), (-0.62, -0.9)], 0.5, mat(RUNNER), bevel=0.16)


def build_dice():
    """ランダムで決まる: さいころ。"""
    box((1.5, 1.5, 1.5), mat(WHITE, emit=0.1), bevel=0.2)
    for x, z in ((-0.4, 0.4), (0.4, 0.4), (0, 0), (-0.4, -0.4), (0.4, -0.4)):
        ball(0.15, mat(PURPLE), loc=(x, -0.74, z), scale=(1, 0.5, 1))


def _medal(color_hex):
    """レート帯のメダル。色は RankingManager.TIERS と同じ。"""
    for sx in (-1, 1):
        prism([(-0.22, 0.6), (0.22, 0.6), (0.22, -0.35), (0.0, -0.15), (-0.22, -0.35)], 0.16,
              mat(VIOLET), bevel=0.03, loc=(sx * 0.3, 0.12, 0.72), rot=(0, sx * 22, 0))
    cyl(0.78, 0.3, mat(color_hex, rough=0.2), bevel=0.08, loc=(0, 0, -0.2))
    prism(star_pts(0.42, 0.19), 0.12, mat(WHITE, emit=0.45), bevel=0.02, loc=(0, -0.2, -0.2))


TIER_COLORS = {"bronze": "#cc8047", "silver": "#c7ccd9", "gold": "#ffcc40",
               "platinum": "#8ce6f2", "diamond": "#8cb3ff", "master": "#d973ff"}


# ---------------------------------------------------------------------
# キー操作のヒント
# ---------------------------------------------------------------------

def _key(width):
    box((width, 0.7, 1.5), mat(DARK), bevel=0.18, loc=(0, 0.1, -0.1))
    box((width - 0.24, 0.5, 1.26), mat(WHITE, emit=0.1), bevel=0.16, loc=(0, -0.16, 0.02))


def build_key():
    """キーの絵（刻印は Godot 側が上に重ねる）。"""
    _key(1.5)


def build_key_wide():
    """Shift / Space / Enter など横長のキー。"""
    _key(3.0)


def _mouse(side):
    box((1.2, 0.6, 1.8), mat(WHITE, emit=0.1), bevel=0.5)
    box((0.06, 0.2, 0.8), mat(PURPLE), bevel=0.0, loc=(0, -0.28, 0.5))
    if side:
        box((0.5, 0.2, 0.72), mat(PINK), bevel=0.1, loc=(side * 0.3, -0.26, 0.5))


def build_mouse():
    """マウスを動かす: 視点。"""
    _mouse(0)


def build_mouse_left():
    _mouse(-1)


def build_mouse_right():
    _mouse(1)


def build_move():
    """移動: 四方の矢印。"""
    for angle in (0, 90, 180, 270):
        prism([(0.0, 0.98), (-0.42, 0.42), (0.42, 0.42)], 0.4, mat(VIOLET), bevel=0.08,
              rot=(0, angle, 0))
    ball(0.26, mat(VIOLET))


def build_bolt():
    """ダッシュ・スタミナ・スピード: 稲妻。"""
    prism([(0.2, 1.0), (-0.62, 0.0), (-0.08, 0.0), (-0.34, -1.0), (0.62, 0.22), (0.08, 0.22),
           (0.5, 1.0)], 0.4, mat(YELLOW), bevel=0.07)


def build_dive():
    """ダイブ: 飛び込むキャラ。"""
    bean(CYAN, "Dive", 22, yaw=52, tilt=(48, 0))


def build_emote():
    """エモート: 吹き出し。"""
    box((1.9, 0.4, 1.3), mat(WHITE, emit=0.1), bevel=0.3, loc=(0, 0, 0.22))
    prism([(-0.5, -0.3), (-0.05, -0.3), (-0.62, -0.95)], 0.4, mat(WHITE, emit=0.1), bevel=0.05)
    prism(star_pts(0.4, 0.17), 0.14, mat(YELLOW), bevel=0.03, loc=(0, -0.24, 0.24))


def build_swap():
    """役割を切りかえる: 入れ替えの矢印。"""
    _arrow(mat(RUNNER), loc=(0.0, 0.0, 0.5))
    _arrow(mat(HUNTER), flip=-1.0, loc=(0.0, 0.0, -0.5))


# ---------------------------------------------------------------------
# 対戦中の HUD
# ---------------------------------------------------------------------

def _eye():
    upper = [(x, z) for x, _, z in arc(0.0, -0.62, 1.2, 31.1, 148.9, n=18)]
    lower = [(x, -z) for x, z in reversed(upper)]
    prism(upper + lower[1:-1], 0.3, mat(WHITE, emit=0.15), bevel=0.06)
    cyl(0.4, 0.2, mat(CYAN), bevel=0.04, loc=(0, -0.14, 0))
    cyl(0.19, 0.2, mat(PURPLE), bevel=0.03, loc=(0, -0.2, 0))


def build_eye():
    """見つけた・見られている: 目。"""
    _eye()


def build_eye_off():
    """手がかりなし: 斜線の入った目。"""
    _eye()
    box((2.5, 0.3, 0.26), mat(HUNTER), bevel=0.08, loc=(0, -0.3, 0), rot=(0, 40, 0))


def build_distance():
    """距離: 両向きの矢印。"""
    prism([(-1.0, 0.0), (-0.45, 0.5), (-0.45, 0.2), (0.45, 0.2), (0.45, 0.5), (1.0, 0.0),
           (0.45, -0.5), (0.45, -0.2), (-0.45, -0.2), (-0.45, -0.5)], 0.36, mat(CYAN), bevel=0.08)


def build_item_rocket():
    """アイテム: ロケット。"""
    tilt = (0, 35, 0)
    lathe([(0.0, -0.7), (0.34, -0.7), (0.42, -0.2), (0.4, 0.35), (0.0, 0.36)], mat(WHITE, emit=0.1),
          rot=tilt)
    lathe([(0.0, 0.34), (0.4, 0.34), (0.28, 0.75), (0.0, 1.1)], mat("#ff8c4d"), rot=tilt)
    for angle in (0, 90, 180, 270):
        fin = prism([(0.3, -0.25), (0.78, -0.85), (0.3, -0.7)], 0.12, mat("#ff8c4d"), bevel=0.03)
        # 機体の軸まわりに羽を配ってから、機体ごと傾ける（Z を先に回す順序にする）
        fin.rotation_mode = "ZYX"
        fin.rotation_euler = Euler((0, math.radians(35), math.radians(angle + 45)), "ZYX")
    ball(0.17, mat(CYAN, emit=0.4), loc=(0.07, -0.36, 0.1))
    lathe([(0.0, -1.15), (0.22, -0.72), (0.0, -0.7)], mat(YELLOW, emit=0.9), rot=tilt)


def build_item_banana():
    """アイテム: バナナ（踏むとすべる）。"""
    pts = arc(0.0, 0.55, 1.0, 205, 335, n=30)
    tube(pts, 0.27, mat("#ffdb33"))
    for p in (pts[0], pts[-1]):
        ball(0.15, mat("#7a5230"), loc=p)


def build_item_block():
    """アイテム: 設置ブロック。"""
    box((1.5, 1.5, 1.5), mat("#73d9ff"), bevel=0.14)
    box((1.05, 0.2, 1.05), mat("#bfeeff"), bevel=0.1, loc=(0, -0.7, 0))


def build_spring():
    """ジャンプのバフ: ばね。"""
    turns, n = 3.0, 90
    pts = [(0.5 * math.cos(2 * math.pi * turns * i / n), 0.5 * math.sin(2 * math.pi * turns * i / n),
            -0.6 + 1.1 * i / n) for i in range(n + 1)]
    tube(pts, 0.1, mat(GREY, emit=0.1))
    cyl(0.75, 0.24, mat(PINK), bevel=0.08, axis="Z", loc=(0, 0, 0.66))
    cyl(0.75, 0.2, mat(DARK), bevel=0.06, axis="Z", loc=(0, 0, -0.72))


def build_warp():
    """ワープ: うずまき。"""
    n = 70
    pts = [((0.12 + 0.85 * i / n) * math.cos(0.085 * i * math.pi), 0.0,
            (0.12 + 0.85 * i / n) * math.sin(0.085 * i * math.pi)) for i in range(n + 1)]
    tube(pts, 0.13, mat("#7dff8a", emit=0.5))


def build_clock():
    """時間: 時計。"""
    cyl(0.98, 0.3, mat(VIOLET), bevel=0.08, loc=(0, 0.06, 0))
    cyl(0.78, 0.3, mat(WHITE, emit=0.15), bevel=0.04, loc=(0, -0.06, 0))
    box((0.13, 0.2, 0.56), mat(PURPLE), bevel=0.04, loc=(0, -0.2, 0.24))
    box((0.13, 0.2, 0.46), mat(PURPLE), bevel=0.04, loc=(0.17, -0.2, -0.05), rot=(0, 115, 0))


def build_lose():
    """負け: 転んだキャラ。"""
    bean("#8fa0c4", "Slip", 30, yaw=40)


def build_tagged():
    """つかまえた人: タッチする手。"""
    box((0.9, 0.42, 0.95), mat("#f8b8b8"), bevel=0.2, loc=(0, 0, -0.35))
    for i, (x, h) in enumerate(((-0.33, 0.62), (-0.11, 0.78), (0.11, 0.72), (0.33, 0.56))):
        box((0.2, 0.36, h), mat("#f8b8b8"), bevel=0.09, loc=(x, 0, 0.1 + h / 2.0))
    box((0.24, 0.36, 0.55), mat("#f8b8b8"), bevel=0.1, loc=(-0.6, 0, -0.25), rot=(0, -38, 0))


# ---------------------------------------------------------------------
# サブ画面（きせかえ・設定など）
# ---------------------------------------------------------------------

def build_character():
    """きせかえのタブ: キャラ。"""
    bean(CYAN, "Idle", 0, yaw=18)


def build_pattern():
    """きせかえのタブ: 柄（ペンキのローラー）。"""
    cyl(0.34, 1.5, mat(PINK), bevel=0.1, axis="Z", loc=(0, 0, 0.5), rot=(0, 90, 0))
    tube([(0.75, 0, 0.5), (1.0, 0, 0.5), (1.0, 0, -0.05), (0.0, 0, -0.05), (0.0, 0, -0.4)], 0.07,
         mat(GREY, emit=0.1))
    cyl(0.14, 0.7, mat(VIOLET), bevel=0.05, axis="Z", loc=(0, 0, -0.7))


def build_palette():
    """きせかえのタブ: 色（パレット）。"""
    cyl(1.0, 0.26, mat("#fff0cf"), bevel=0.08, scale=(1.0, 1.0, 0.8))
    for a, color in ((150, HUNTER), (100, YELLOW), (50, RUNNER), (0, CYAN), (-50, VIOLET)):
        ball(0.17, mat(color), scale=(1, 0.6, 1),
             loc=(0.62 * math.cos(math.radians(a)), -0.14, 0.5 * math.sin(math.radians(a))))
    cyl(0.2, 0.3, mat(PURPLE), bevel=0.0, loc=(-0.35, 0.0, -0.3))


def build_hat():
    """きせかえのタブ: 帽子（パーティーハット）。"""
    lathe([(0.0, -0.6), (0.62, -0.6), (0.0, 0.85)], mat(PINK))
    for z, r in ((-0.3, 0.5), (0.15, 0.31)):
        cyl(r, 0.14, mat(YELLOW), bevel=0.0, axis="Z", loc=(0, 0, z))
    ball(0.2, mat(CYAN), loc=(0, 0, 0.92))


def build_matches():
    """対戦回数: ゲームパッド。"""
    box((2.0, 0.5, 1.1), mat(VIOLET), bevel=0.38)
    box((0.52, 0.2, 0.17), mat(WHITE), bevel=0.04, loc=(-0.52, -0.26, 0.05))
    box((0.17, 0.2, 0.52), mat(WHITE), bevel=0.04, loc=(-0.52, -0.26, 0.05))
    ball(0.14, mat(HUNTER), loc=(0.42, -0.26, -0.05), scale=(1, 0.6, 1))
    ball(0.14, mat(YELLOW), loc=(0.7, -0.26, 0.18), scale=(1, 0.6, 1))


def build_winrate():
    """勝率: 円グラフ。"""
    whole = [(x, z) for x, _, z in arc(0, 0, 0.95, 90, 360, n=40)] + [(0.0, 0.0)]
    prism(whole, 0.34, mat(CYAN), bevel=0.06)
    wedge = [(x, z) for x, _, z in arc(0, 0, 0.95, 0, 90, n=16)] + [(0.0, 0.0)]
    prism(wedge, 0.34, mat(YELLOW), bevel=0.06, loc=(0.12, 0, 0.12))


def build_volume():
    """音量: スピーカー。"""
    prism([(-0.95, 0.3), (-0.5, 0.3), (0.05, 0.8), (0.05, -0.8), (-0.5, -0.3), (-0.95, -0.3)], 0.4,
          mat(VIOLET), bevel=0.08)
    for r in (0.38, 0.72):
        tube(arc(0.1, 0.0, r, -50, 50), 0.09, mat(CYAN))


def build_touch():
    """タッチ操作: 画面を押す指。"""
    tube(arc(0.0, 0.42, 0.6, 20, 160), 0.08, mat(CYAN))
    tube(arc(0.0, 0.42, 0.9, 35, 145), 0.08, mat(CYAN))
    box((0.34, 0.36, 1.2), mat("#f8b8b8"), bevel=0.16, loc=(0, 0, -0.1))
    box((0.95, 0.4, 0.7), mat("#f8b8b8"), bevel=0.22, loc=(0.16, 0.02, -0.72))


def build_language():
    """言語: 地球。"""
    ball(0.9, mat(CYAN))
    white = mat(WHITE, emit=0.2)
    ring = arc(0, 0, 0.93, 0, 360, n=48)
    tube(ring, 0.05, white, cyclic=True, rot=(90, 0, 0))
    for angle in (-52, 52):
        tube(ring, 0.05, white, cyclic=True, rot=(0, 0, angle))


def build_text_size():
    """文字サイズ: 小さい A と大きい A。"""
    letter("A", 1.0, WHITE, VIOLET, loc=(-0.75, 0, -0.28))
    letter("A", 1.9, WHITE, VIOLET, loc=(0.42, 0, 0.0))


def build_win():
    """勝ち: 紙吹雪つきのトロフィー。"""
    build_ranking()
    for i, color in enumerate((PINK, CYAN, RUNNER, VIOLET, PINK, CYAN, RUNNER, YELLOW)):
        a = 2.4 * i
        box((0.2, 0.05, 0.12), mat(color), bevel=0.0,
            loc=(1.05 * math.cos(a), 0.0, 1.35 + 0.75 * math.sin(a * 1.7)), rot=(20 * i, 35 * i, 50 * i))


def build_taunt_1():
    """挑発「前のめり」。"""
    bean(CYAN, "Come", 6, yaw=24)


def build_taunt_2():
    """挑発「腰ふり」。"""
    bean(PINK, "ComeHip", 5, yaw=24)


def build_taunt_3():
    """挑発「余裕」。"""
    bean(YELLOW, "ComeCool", 8, yaw=24)


# 名前 -> (組み立て関数, 出力先, 幅, 高さ, 余白を切り詰めるか)。出力先 None は ui/icons/<名前>.png
ART = {
    "logo": (build_logo, os.path.join(LOGO_DIR, "reverse_tag_logo.png"), 1024, 640, True),
    "mark": (build_mark, os.path.join(LOGO_DIR, "reverse_tag_mark.png"), 512, 512, False),
}
# 大きく見せる絵（メニューの主役・役割・結果）は 256、それ以外は 128。
# 128 でも文字サイズ「特大」(1.3倍) の 64px 表示に対して十分な解像度がある
for _name in ("play", "solo", "costume", "shop", "friends", "ranking", "settings", "quit",
              "role_runner", "role_hunter", "start", "win", "lose"):
    ART[_name] = (globals()["build_" + _name], None, 256, 256, False)
for _name in ("ok", "cancel", "back", "refresh", "plus", "search", "stop", "link", "gem", "lock",
              "gift", "fullscreen", "cpu", "crown", "hourglass", "dice", "key", "mouse",
              "mouse_left", "mouse_right", "move", "bolt", "dive", "emote", "swap", "eye",
              "eye_off", "distance", "item_rocket", "item_banana", "item_block", "spring", "warp",
              "clock", "tagged", "character", "pattern", "palette", "hat", "matches", "winrate",
              "volume", "touch", "language", "text_size", "taunt_1", "taunt_2", "taunt_3"):
    ART[_name] = (globals()["build_" + _name], None, 128, 128, False)
ART["key_wide"] = (build_key_wide, None, 256, 128, False)
for _tier, _color in TIER_COLORS.items():
    ART["tier_" + _tier] = (lambda c=_color: _medal(c), None, 128, 128, False)


def out_path(name):
    return ART[name][1] or os.path.join(ICON_DIR, name + ".png")


def make_sheet(out_dir, names):
    """全部を並べた一覧。小さくしても、暗い背景でも明るい背景でも形が分かるかを見る。

    上にロゴとシンボル、下に全アイコンを 128px で、明るい段と暗い段の2回並べる。
    """
    os.makedirs(out_dir, exist_ok=True)
    cell, cols = 140, 12
    icons = [n for n in names if ART[n][1] is None]
    rows = (len(icons) + cols - 1) // cols
    logo = _load_pixels(out_path("logo"))
    mark = _load_pixels(out_path("mark"))
    top = max(logo.shape[0], mark.shape[0]) + 40
    width = max(cell * cols, logo.shape[1] + mark.shape[1] + 60)
    height = top + rows * cell * 2
    sheet = np.ones((height, width, 4), dtype=np.float32)
    sheet[..., :3] = _hex_rgb("#7c4dff")
    # 画像の行は下から上へ並ぶ。下の rows*cell 行が暗い段
    sheet[:rows * cell, :, :3] = _hex_rgb("#1a1c2e")

    def paste(px, x, y_top):
        h, w = px.shape[:2]
        y0 = height - y_top - h
        region = sheet[y0:y0 + h, x:x + w]
        rgb, _ = _over(region[..., :3], region[..., 3], px[..., :3], px[..., 3])
        region[..., :3] = rgb

    paste(logo, 20, 20)
    paste(mark, 40 + logo.shape[1], 20)
    for i, name in enumerate(icons):
        px = _load_pixels(out_path(name))
        while px.shape[0] > 128:
            h, w = px.shape[:2]
            a = px[..., 3].reshape(h // 2, 2, w // 2, 2)
            c = (px[..., :3].reshape(h // 2, 2, w // 2, 2, 3) * a[..., None]).sum(axis=(1, 3))
            px = np.dstack([c / np.maximum(a.sum(axis=(1, 3)), 1e-6)[..., None],
                            a.mean(axis=(1, 3))])
        for band in (0, 1):
            x = (i % cols) * cell + (cell - min(px.shape[1], cell)) // 2
            y = top + band * rows * cell + (i // cols) * cell + 6
            paste(px[:, :cell], x, y)
    path = os.path.join(out_dir, "ui_art_sheet.png")
    _save_pixels(path, sheet)
    print("sheet  :", path)


def make_app_icons():
    """シンボルを紺の角丸の板に載せたアプリアイコンの候補。

    docs/concept/store/app_icon/SPEC.md の配色（背景 #2b3a67）に合わせる。
    ここで出すのは候補だけで、icon.svg / icon.ico への組み込みは REVIEW.md の判定後に行う。
    """
    out_dir = os.path.join(PROJECT, "docs", "concept", "store", "app_icon")
    reset()
    build_mark()
    tmp = os.path.join(tempfile.gettempdir(), "ui_art_app_icon.png")
    shoot(tmp, 832)
    mark = _load_pixels(tmp)
    size, radius = 1024, 200
    yy, xx = np.mgrid[0:size, 0:size]
    # 角丸の板: 四隅の円の外側だけを落とす
    cx = np.clip(xx, radius, size - 1 - radius)
    cy = np.clip(yy, radius, size - 1 - radius)
    plate_a = np.clip(radius + 0.5 - np.hypot(xx - cx, yy - cy), 0.0, 1.0).astype(np.float32)
    rgb = np.broadcast_to(_hex_rgb("#2b3a67"), (size, size, 3)).copy()
    off = (size - mark.shape[0]) // 2
    region = rgb[off:off + mark.shape[0], off:off + mark.shape[1]]
    blended, _ = _over(region, np.ones(mark.shape[:2], dtype=np.float32), mark[..., :3], mark[..., 3])
    rgb[off:off + mark.shape[0], off:off + mark.shape[1]] = blended
    icon = np.dstack([rgb, plate_a])
    for px in (1024, 256, 16):
        k = size // px
        blocks = icon.reshape(px, k, px, k, 4)
        a = blocks[..., 3]
        c = (blocks[..., :3] * a[..., None]).sum(axis=(1, 3)) / np.maximum(a.sum(axis=(1, 3)), 1e-6)[..., None]
        # 正式なアイコン（オーナー提供の reverse_tag_icon_*.png）を上書きしないよう別名で出す
        path = os.path.join(out_dir, "reverse_tag_mark_icon_%d.png" % px)
        _save_pixels(path, np.dstack([c, a.mean(axis=(1, 3))]))
        print("icon   :", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--app-icon" in argv:
        make_app_icons()
        return
    names = list(ART)
    if "--only" in argv:
        names = argv[argv.index("--only") + 1].split(",")
    for name in names:
        builder, _, width, height, trim = ART[name]
        reset()
        builder()
        if name == "logo":
            shoot(out_path(name), width, height, yaw=-10.0, pitch=4.0, trim=trim)
        else:
            shoot(out_path(name), width, height, trim=trim)
    if "--sheet" in argv:
        out_dir = argv[argv.index("--sheet") + 1]
        if not os.path.isabs(out_dir):
            out_dir = os.path.join(PROJECT, out_dir)
        make_sheet(out_dir, list(ART))


main()
