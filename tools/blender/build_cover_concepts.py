"""ストアのカバー画像の別案（KAN-87）を、ゲームと同じキャラのモデルから Blender で描いて PNG に書き出す。

    blender -b -P tools/blender/build_cover_concepts.py -- <出力ディレクトリ> [--only a,b] [--scale 2] [--draft] [--sheet]

案は4つで、どれも 630x500（itch.io のカバー）に「REVERSE TAG!」とゲームのキャラ（きょうりゅう）を入れる。
各案のねらいは docs/concept/store/cover_image/CONCEPTS.md。

    a  つかまる寸前    低いカメラで、逃げる緑のすぐ後ろへ角の赤が飛びつく一瞬
    b  逆転            赤と緑に斜めに分けた背景で、入れ替わりの矢印の輪の中に背中合わせの2人
    c  遊び場ジオラマ  空に浮かぶ島のマップを見下ろし、滑り台の緑と探し回る赤
    d  4対4パーティー  Reverse Tag モードの青と橙の2チームが、帽子をかぶって並ぶ集合写真

描き方は3層の重ね合わせ:
    背景（numpy で描く 2D のグラデーション・放射線・雲） → 3D の絵（透明背景で描く） → タイトル
3D の絵とタイトルには、ゲームのロゴ・アイコン（build_ui_art.py）と同じ「濃い紫のふち＋白いふち」を
付けられる。背景を 2D にしたのは、空の色や斜めの塗り分けを 3D の環境光から切り離して、
SPEC の配色をそのまま出すため（v1 は空の色を環境光から分けるのにワールドのノードを組んでいた）。

部品は v1（build_cover_art.py）とロゴ（build_ui_art.py）から import して使う。どちらも
`if __name__ == "__main__"` で囲ってあるので、import しても絵は描き直されない。
--draft は構図を詰めるための粗い試し描き（等倍・少ないサンプル）。
--sheet を付けると、比較用の一覧 cover_v2_sheet.png も出す（--sheet-only なら描き直さず一覧だけ作る）。
"""

import math
import os
import sys
import tempfile

import bpy
import numpy as np
from mathutils import Euler, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import build_cover_art as v1  # noqa: E402
import build_ui_art as ui  # noqa: E402

BLEND_DIR = HERE
DINO_BLEND = os.path.join(BLEND_DIR, "fallguy.blend")

W, H = 630, 500

# ---- 配色（sRGB の 16 進）。SPEC.md の正本と、ゲームのチーム色 ----
RUNNER = "#22c55e"
HUNTER = "#ef4444"
YELLOW = "#facc15"
LIME = "#a3e635"
SKY_BLUE = "#38bdf8"
PURPLE = "#a78bfa"
PINK = "#f9a8d4"
HOT_PINK = "#f472b6"
WHITE = "#ffffff"
ORANGE = "#fb923c"
# autoload/game/team_mode.gd の TEAM_COLORS（Color(0.3, 0.62, 1.0) と Color(1.0, 0.6, 0.18)）
TEAM_A = "#4d9eff"
TEAM_B = "#ff992e"
# scenes/humanoid.gd の GHOST_COLOR（Color(0.72, 0.86, 1.0, 0.45)）
GHOST = "#b8dbff"
GHOST_ALPHA = 0.45

STATE = {"scale": 2, "draft": False}


# =====================================================================
# 2D（numpy）。配列は Blender の画像と同じく「下の行から上へ」並ぶ、sRGB の 0〜1
# =====================================================================

def rgb(hex_color):
    return ui._hex_rgb(hex_color)


def canvas_size():
    return W * STATE["scale"], H * STATE["scale"]


def grid():
    """各画素の (x, y)。どちらも 0〜1 で、y は上が 1。"""
    w, h = canvas_size()
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return xs / (w - 1), ys / (h - 1)


def vertical(top_hex, bottom_hex, power=1.0):
    _, y = grid()
    t = (y ** power)[..., None]
    return rgb(bottom_hex) * (1.0 - t) + rgb(top_hex) * t


def paint(base, color_hex, mask):
    """mask（0〜1）の濃さで色を塗る。"""
    m = np.clip(mask, 0.0, 1.0)[..., None]
    return base * (1.0 - m) + rgb(color_hex) * m


def smooth(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def rays(cx, cy, count, phase=0.0):
    """(cx, cy) から放射する扇。1 と 0 が交互に並ぶ。"""
    x, y = grid()
    aspect = W / H
    ang = np.arctan2(y - cy, (x - cx) * aspect)
    return (np.sin(ang * count + phase) > 0.0).astype(np.float32)


def blob(cx, cy, rx, ry):
    """楕円の中を 1 にする（ふちは 1px ぶんなめらかに）。座標は 0〜1（y は上が 1）。
    rx は横幅に対する割合、ry は高さに対する割合。"""
    x, y = grid()
    d = np.sqrt(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2)
    edge = 1.5 / (W * STATE["scale"] * rx)
    return 1.0 - smooth(1.0 - edge, 1.0 + edge, d)


def cloud(base, cx, cy, size, color_hex=WHITE, alpha=1.0):
    """丸を3つ重ねた平たい雲。size は横幅に対する割合。"""
    m = np.zeros(base.shape[:2], dtype=np.float32)
    k = W / H  # 横幅の割合を高さの割合へ
    for dx, dy, r in ((-0.55, 0.0, 0.55), (0.0, 0.18, 0.75), (0.6, 0.02, 0.5)):
        m = np.maximum(m, blob(cx + dx * size, cy + dy * size * k, r * size, r * size * k * 0.62))
    return paint(base, color_hex, m * alpha)


def streaks(cx, cy, count, inner, seed=3):
    """(cx, cy) から外へ向かう細い速度線。inner より内側は消す。"""
    x, y = grid()
    aspect = W / H
    dx, dy = (x - cx) * aspect, y - cy
    ang = np.arctan2(dy, dx)
    dist = np.sqrt(dx * dx + dy * dy)
    rng = np.random.default_rng(seed)
    m = np.zeros_like(x)
    for _ in range(count):
        a0 = rng.uniform(-math.pi, math.pi)
        width = rng.uniform(0.004, 0.012)
        start = inner + rng.uniform(0.0, 0.25)
        d_ang = np.abs(np.angle(np.exp(1j * (ang - a0))))
        line = 1.0 - smooth(width * 0.6, width, d_ang)
        m = np.maximum(m, line * smooth(start, start + 0.12, dist))
    return m


def over(base_rgb, layer, x0=0, y0=0):
    """RGBA の layer を、base の (x0, y0)（左下が原点の画素）へ重ねる。"""
    h, w = layer.shape[:2]
    bh, bw = base_rgb.shape[:2]
    xa, ya = max(x0, 0), max(y0, 0)
    xb, yb = min(x0 + w, bw), min(y0 + h, bh)
    if xa >= xb or ya >= yb:
        return base_rgb
    src = layer[ya - y0:yb - y0, xa - x0:xb - x0]
    region = base_rgb[ya:yb, xa:xb]
    a = src[..., 3:4]
    base_rgb[ya:yb, xa:xb] = src[..., :3] * a + region * (1.0 - a)
    return base_rgb


def outline(px, thickness, rim=None, drop=None, ink_hex=ui.PURPLE):
    """透明背景の絵に、ロゴと同じ「濃い紫のふち＋下へずらした厚み＋白いふち」を付ける。
    thickness は画素数。rim と drop を省くとロゴと同じ比率にする。"""
    rim = thickness * ui.RIM / ui.OUTLINE if rim is None else rim
    drop = thickness * ui.DROP / ui.OUTLINE if drop is None else drop
    color, alpha = px[..., :3], px[..., 3]
    ink = ui._dilate(alpha, thickness)
    d = int(round(drop))
    if d > 0:
        lowered = np.zeros_like(ink)
        lowered[:-d, :] = ink[d:, :]
        ink = np.maximum(ink, lowered)
    ring = ui._dilate(ink, rim) if rim > 0 else ink
    out_rgb = np.broadcast_to(rgb(WHITE), color.shape).copy()
    out_rgb, out_a = ui._over(out_rgb, ring, np.broadcast_to(rgb(ink_hex), color.shape), ink)
    out_rgb, out_a = ui._over(out_rgb, out_a, color, alpha)
    return np.dstack([out_rgb, out_a])


def finish(px_rgb, path):
    """2倍で描いた絵を 630x500 へ縮めて保存する。"""
    s = STATE["scale"]
    h, w = px_rgb.shape[0] // s, px_rgb.shape[1] // s
    small = px_rgb[:h * s, :w * s].reshape(h, s, w, s, 3).mean(axis=(1, 3))
    ui._save_pixels(path, np.dstack([small, np.ones((h, w), dtype=np.float32)]))
    print("render :", path, w, "x", h)


# =====================================================================
# 3D
# =====================================================================

def reset_scene(ortho=False):
    """v1 と同じ光（左上手前の主光＋弱い補助光、白い弱い環境光）で、背景だけ透明にする。"""
    if ortho:
        ui.reset()
    else:
        v1.reset()
        scene = bpy.context.scene
        scene.render.film_transparent = True
        scene.render.image_settings.color_mode = "RGBA"
    # 工場出荷状態に戻すとマテリアルは消えるので、v1 と ui の作り置きも捨てる
    v1._MATS.clear()
    ui._MATS.clear()
    scene = bpy.context.scene
    scene.eevee.taa_render_samples = 16 if STATE["draft"] else 64


def perspective_camera(loc, target, lens, dof_target=None, fstop=4.0):
    scene = bpy.context.scene
    data = bpy.data.cameras.new("Cam")
    data.lens = lens
    cam = bpy.data.objects.new("Cam", data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    if dof_target is not None:
        data.dof.use_dof = True
        data.dof.focus_distance = (Vector(dof_target) - Vector(loc)).length
        data.dof.aperture_fstop = fstop
    return cam


def objects_of(rig):
    return [rig] + list(rig.children_recursive)


def char(body_hex, clip, frame, loc=(0, 0, 0), yaw=0.0, tilt=(0.0, 0.0), scale=1.0,
         blend=DINO_BLEND, emit=0.12):
    """ゲームのキャラを指定のアニメの1コマで立たせる（v1 の bean() と同じ手順）。
    body_hex が None なら体の色を塗り替えない（固定デザインのキャラ用）。"""
    with bpy.data.libraries.load(blend, link=False) as (src, dst):
        dst.objects = list(src.objects)
    rig = None
    for obj in dst.objects:
        bpy.context.scene.collection.objects.link(obj)
        if obj.type == "ARMATURE":
            rig = obj
    for obj in dst.objects:
        if obj.type != "MESH" or body_hex is None:
            continue
        for slot in obj.material_slots:
            if slot.material and slot.material.name.split(".")[0] == "Body":
                c = v1.srgb(body_hex)
                bsdf = next(n for n in slot.material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
                bsdf.inputs["Base Color"].default_value = (*c, 1.0)
                bsdf.inputs["Roughness"].default_value = 0.32
                bsdf.inputs["Emission Color"].default_value = (*c, 1.0)
                bsdf.inputs["Emission Strength"].default_value = emit
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
    rig.rotation_euler = Euler((math.radians(tilt[0]), math.radians(tilt[1]), math.radians(yaw)), "XYZ")
    rig.scale = (scale, scale, scale)
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    anim.action = None
    return rig


def ghostify(rig):
    """Reverse Tag の幽霊。ゲームと同じ水色で半透明にする。"""
    m = bpy.data.materials.new("Ghost")
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    c = v1.srgb(GHOST)
    bsdf.inputs["Base Color"].default_value = (*c, 1.0)
    bsdf.inputs["Emission Color"].default_value = (*c, 1.0)
    bsdf.inputs["Emission Strength"].default_value = 0.5
    bsdf.inputs["Alpha"].default_value = GHOST_ALPHA
    try:
        m.surface_render_method = "BLENDED"
    except (AttributeError, TypeError):
        m.blend_method = "BLEND"
    for obj in rig.children_recursive:
        if obj.type == "MESH":
            obj.data.materials.clear()
            obj.data.materials.append(m)


# 帽子の装着位置。autoload/hat_catalog.gd の offset（Chest ボーンの原点から上へ）と同じ値
HAT_OFFSET = {"HatParty": 0.48, "HatCap": 0.42, "HatPropeller": 0.50, "HatWizard": 0.56,
              "HatCrown": 0.57, "HatCatEars": 0.58}
CHEST_LENGTH = 0.56  # Chest ボーンの長さ（humanoid.gd の説明と同じ）


def hat(rig, name):
    """hats.blend の帽子を Chest ボーンへ付ける（ゲームの HatAttachment と同じ付け方）。"""
    with bpy.data.libraries.load(os.path.join(BLEND_DIR, "hats.blend"), link=False) as (src, dst):
        dst.objects = [name]
    obj = dst.objects[0]
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = rig
    obj.parent_type = "BONE"
    obj.parent_bone = "Chest"
    # ボーンの子は「ボーンの先端」が原点で、Y がボーンの向き（上）。帽子は Z が上で作ってある
    obj.location = (0.0, HAT_OFFSET[name] - CHEST_LENGTH, 0.0)
    obj.rotation_euler = Euler((math.radians(-90), 0.0, 0.0), "XYZ")
    return obj


def prop(blend, names, loc=(0, 0, 0), yaw=0.0, scale=1.0):
    """小物の .blend から指定の物だけを読み込み、まとめて置く。"""
    with bpy.data.libraries.load(os.path.join(BLEND_DIR, blend), link=False) as (src, dst):
        dst.objects = [n for n in src.objects if n in names]
    root = bpy.data.objects.new("Prop_" + blend, None)
    bpy.context.scene.collection.objects.link(root)
    for obj in dst.objects:
        bpy.context.scene.collection.objects.link(obj)
        if obj.parent is None or obj.parent.name not in names:
            obj.parent = root
    root.location = loc
    root.rotation_euler = Euler((0, 0, math.radians(yaw)), "XYZ")
    root.scale = (scale, scale, scale)
    return root


def render_rgba(keep=None):
    """今のカメラで透明背景のまま描いて、RGBA の配列で返す。keep を渡すとそれ以外を隠す。"""
    scene = bpy.context.scene
    hidden = []
    if keep is not None:
        keep = set(keep)
        for obj in scene.objects:
            if obj.type in {"MESH", "CURVE", "FONT"} and obj not in keep and not obj.hide_render:
                obj.hide_render = True
                hidden.append(obj)
    w, h = canvas_size()
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.render.resolution_percentage = 100
    tmp = os.path.join(tempfile.gettempdir(), "cover_concept_layer.png")
    scene.render.filepath = tmp
    bpy.ops.render.render(write_still=True)
    for obj in hidden:
        obj.hide_render = False
    return ui._load_pixels(tmp)


def shoot_box(width, height, yaw=0.0, pitch=0.0, thickness=None, bare=()):
    """ui.reset() の平行投影の場面を、width x height 画素の箱にちょうど収めて描き、ふちを付けて返す。
    箱の大きさはキャンバス（2倍）の画素数。ふちの付け方はロゴ（ui.shoot）と同じで、2倍で描いて縮める。

    bare に渡した物（半透明の幽霊など）は、ふちを付けずに別に描いて上に重ねる。ふちの層の上に
    半透明の物を描くと、紫のふちが透けて濁るため。"""
    scene = bpy.context.scene
    ss = ui.SUPERSAMPLE
    scene.render.resolution_x = width * ss
    scene.render.resolution_y = height * ss
    scene.render.resolution_percentage = 100
    # 収まり具合は bare の物も含めて決める（隠すのはそのあと）
    ui._fit_camera(width, height, yaw, pitch)
    bare = set(bare)
    for obj in bare:
        obj.hide_render = True
    tmp = os.path.join(tempfile.gettempdir(), "cover_concept_box.png")
    scene.render.filepath = tmp
    bpy.ops.render.render(write_still=True)
    px = ui._load_pixels(tmp)
    if thickness is None:
        thickness = ui.OUTLINE * min(width, height) * ss
    out = outline(px, thickness * 1.0)
    if bare:
        hidden = [o for o in scene.objects if o.type in {"MESH", "CURVE", "FONT"} and o not in bare
                  and not o.hide_render]
        for obj in hidden:
            obj.hide_render = True
        for obj in bare:
            obj.hide_render = False
        bpy.ops.render.render(write_still=True)
        ghost = ui._load_pixels(tmp)
        for obj in hidden:
            obj.hide_render = False
        # 明るい背景でも輪郭が分かるよう、白いにじみを薄く敷いてから重ねる
        glow = ui._dilate(ghost[..., 3], thickness * 0.5) * 0.55
        rgb_, a_ = ui._over(out[..., :3], out[..., 3], np.broadcast_to(rgb(WHITE), out[..., :3].shape), glow)
        rgb_, a_ = ui._over(rgb_, a_, ghost[..., :3], ghost[..., 3])
        out = np.dstack([rgb_, a_])
    h2, w2 = out.shape[0] // ss, out.shape[1] // ss
    blocks = out[:h2 * ss, :w2 * ss].reshape(h2, ss, w2, ss, 4)
    a = blocks[..., 3]
    c = (blocks[..., :3] * a[..., None]).sum(axis=(1, 3)) / np.maximum(a.sum(axis=(1, 3)), 1e-6)[..., None]
    return np.dstack([c, a.mean(axis=(1, 3))])


# =====================================================================
# タイトル（全案共通の書体と色。ゲームのロゴ build_ui_art.build_logo と同じ）
# =====================================================================

def build_title(arrows=True, one_line=False):
    """「REVERSE」「TAG!」。ロゴと同じ書体・色・弾み方で、キャラは入れない（キャラは各案の絵に任せる）。"""
    if one_line:
        objs_before = set(bpy.context.scene.objects)
        top = ui._word("REVERSE", 1.9, "#ff5a5a", "#b3202c", 0.0, (-6, 5, -4, 6, -5, 4, -6))
        rev = [o for o in bpy.context.scene.objects if o not in objs_before]
        objs_before = set(bpy.context.scene.objects)
        bottom = ui._word("TAG!", 2.5, ui.YELLOW, ui.ORANGE, -0.15, (-5, 6, -4, 5))
        tag = [o for o in bpy.context.scene.objects if o not in objs_before]
        gap = 0.55
        total = top + gap + bottom
        for o in rev:
            o.location.x += -total / 2.0 + top / 2.0
        for o in tag:
            o.location.x += total / 2.0 - bottom / 2.0
        return
    top = ui._word("REVERSE", 1.45, "#ff5a5a", "#b3202c", 2.4, (-6, 5, -4, 6, -5, 4, -6))
    ui._word("TAG!", 2.7, ui.YELLOW, ui.ORANGE, 0.0, (-5, 6, -4, 5))
    if arrows:
        wing = top / 2.0 + 0.7
        ui.swap_arrows(-wing - 0.95, 1.9, 0.85, rad=0.21, span=-130, arcs=((170, ui.HUNTER),))
        ui.swap_arrows(wing + 0.95, 1.9, 0.85, rad=0.21, span=130, arcs=((10, ui.RUNNER),))


def title_layer(width, height, **kw):
    reset_scene(ortho=True)
    build_title(**kw)
    return shoot_box(width, height, yaw=-6.0, pitch=4.0)


def px(x, y):
    """仕上がり（630x500、左上原点）の座標を、キャンバス（2倍、左下原点）の画素へ。"""
    s = STATE["scale"]
    return int(round(x * s)), int(round((H - y) * s))


def place(base, layer, cx, cy):
    """layer の中心を、仕上がり座標 (cx, cy)（左上原点）へ置く。"""
    x, y = px(cx, cy)
    h, w = layer.shape[:2]
    return over(base, layer, x - w // 2, y - h // 2)


# =====================================================================
# 案 A: つかまる寸前（Close Call）
# =====================================================================

def backdrop_map(y0=18.0):
    """奥にぼけて見える段丘のマップ（v1 と同じゾーンの色・塔・滑り台）。"""
    v1.box((26, 10, 1.6), v1.mat(SKY_BLUE, 0.6), loc=(-14, y0 + 4, 0.8), bevel=0.15)
    v1.box((20, 10, 2.6), v1.mat(PURPLE, 0.6), loc=(8, y0 + 8, 1.3), bevel=0.15)
    v1.box((22, 10, 1.1), v1.mat(PINK, 0.6), loc=(17, y0 + 1, 0.55), bevel=0.15)
    v1.tower(-16, y0 + 3, 1.5, 3.4, RUNNER)
    v1.tower(-8, y0 + 7, 1.1, 2.6, SKY_BLUE)
    v1.tower(12, y0 + 6, 1.4, 3.0, HOT_PINK)
    v1.tower(20, y0 + 3, 1.8, 3.8, PURPLE)
    v1.box((3.4, 12, 0.22), v1.mat(HOT_PINK), loc=(-4.5, y0 - 3.5, 1.25), rot=(11, 0, 0), bevel=0.06)
    v1.box((1.0, 12, 0.25), v1.mat("#bae6fd"), loc=(-4.5, y0 - 3.5, 1.32), rot=(11, 0, 0), bevel=0.05)


def concept_a(path):
    s = STATE["scale"]
    base = vertical("#38bdf8", "#e0f2fe", power=0.8)

    reset_scene()
    v1.box((120, 80, 1), v1.mat(LIME, 0.6), loc=(0, 20, -0.5), bevel=0.0)
    backdrop_map()
    v1.present(-3.2, 5.0)
    v1.present(3.6, 8.5)
    # ゲームのダッシュパネル（実物のモデル）。逃げる人が踏んで加速した、という場面
    prop("boost_panel.blend", {"DashPad", "Plate", "Frame"}, loc=(-0.2, 0.3, 0.0), yaw=-50, scale=0.26)
    # 左手前へ逃げる緑と、右奥から同じ向きへ飛びつく赤。顔が見えるよう、どちらも斜め前を向かせる
    runner = char(RUNNER, "Run", 0, loc=(-0.35, -0.2, 0.0), yaw=-32, scale=1.0)
    hunter = char(HUNTER, "Dive", 22, loc=(1.0, 1.0, 0.62), yaw=-38, tilt=(36, 0), scale=1.0)
    v1.horns(hunter)
    perspective_camera((0.3, -2.9, 0.95), (0.3, 1.0, 1.15), 24, dof_target=(0.2, 0.3, 0.9), fstop=2.0)

    scene_px = render_rgba()
    base = over(base, scene_px)
    # 速度線: 画面の外周だけに白く入れる（キャラの周りには掛けない）
    base = paint(base, WHITE, streaks(0.42, 0.45, 70, 0.42) * 0.75)
    chars = render_rgba(keep=objects_of(runner) + objects_of(hunter))
    base = over(base, outline(chars, 5.0 * s, rim=2.5 * s, drop=2.0 * s))

    title = title_layer(int(500 * s), int(165 * s))
    base = place(base, title, 315, 92)
    finish(base, path)


# =====================================================================
# 案 B: 逆転（Reverse!）
# =====================================================================

def concept_b(path):
    s = STATE["scale"]
    # 背景: 左上から右下へ斜めに、赤の側と緑の側へ分ける。鬼（赤）は緑の側、逃げる人（緑）は赤の側に
    # 立たせて「立場が入れ替わる」を色でも見せる。塗りは SPEC の色を明るくした地に、同じ色の放射線
    x, y = grid()
    split = x * 1.0 + (1.0 - y) * 0.55
    right = split > 0.78  # True が右下（赤の地。緑の逃げる人が立つ）
    base = np.where(right[..., None], rgb("#fecaca"), rgb("#bbf7d0"))
    r = rays(0.5, 0.58, 14)
    base = paint(base, "#fca5a5", r * right * 0.6)
    base = paint(base, "#86efac", r * (~right) * 0.6)
    # 境目の黄色い帯（アクセント）
    base = paint(base, YELLOW, 1.0 - smooth(0.012, 0.016, np.abs(split - 0.78)))

    # 絵: 入れ替わりの矢印の輪の中で、背中合わせの2人。赤い矢印は鬼から逃げる人の側へ、
    # 緑の矢印は逃げる人から鬼の側へ向かう（ロゴの肩の矢印と同じ向きの意味）
    reset_scene(ortho=True)
    hunter = char(HUNTER, "ComeCool", 10, loc=(-0.62, 0.0, 0.0), yaw=-38, scale=1.15, emit=0.22)
    v1.horns(hunter)
    char(RUNNER, "Nice", 9, loc=(0.62, 0.0, 0.0), yaw=38, scale=1.15, emit=0.22)
    ui.swap_arrows(0.0, 1.0, 1.55, rad=0.16, span=-130, y=0.7, arcs=((155, ui.HUNTER), (335, ui.RUNNER)))
    art = shoot_box(int(440 * s), int(330 * s), yaw=0.0, pitch=6.0)
    base = place(base, art, 315, 190)

    title = title_layer(int(600 * s), int(150 * s), arrows=False, one_line=True)
    base = place(base, title, 315, 418)
    finish(base, path)


# =====================================================================
# 案 C: 遊び場ジオラマ（Playground）
# =====================================================================

def tower_at(x, y, z, r, h, color):
    """段の上にも立てられる塔（v1.tower は地面 z=0 にしか立たない）。"""
    v1.cyl(r, h, v1.mat(color), loc=(x, y, z + h / 2))
    v1.cyl(r * 1.3, h * 0.8, v1.mat(color), loc=(x, y, z + h + h * 0.4), r2=0.0)


def ortho_camera(direction, target, scale):
    scene = bpy.context.scene
    data = bpy.data.cameras.new("Cam")
    data.type = "ORTHO"
    data.ortho_scale = scale
    data.clip_end = 400.0
    cam = bpy.data.objects.new("Cam", data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    d = Vector(direction).normalized()
    cam.location = Vector(target) + d * 120.0
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    return cam


def concept_c(path):
    s = STATE["scale"]
    base = vertical("#7dd3fc", "#e0f2fe", power=0.9)
    for cx, cy, size in ((0.08, 0.5, 0.07), (0.93, 0.58, 0.08), (0.88, 0.95, 0.05), (0.1, 0.93, 0.05)):
        base = cloud(base, cx, cy, size)

    reset_scene()
    # 島: 芝の天面、土の側面、下へすぼまる岩
    v1.box((26, 18, 1.0), v1.mat(LIME, 0.6), loc=(0, 0, -0.5), bevel=0.45)
    v1.box((25.4, 17.4, 2.2), v1.mat("#e8a765", 0.8), loc=(0, 0, -1.9), bevel=0.5)
    v1.cyl(1.5, 9.0, v1.mat("#c98a4b", 0.8), loc=(0, 0, -7.4), r2=11.5)
    # ゾーンの段（奥が高い）。色は SPEC のゾーン色
    v1.box((10, 7, 1.6), v1.mat(SKY_BLUE, 0.6), loc=(-7.5, 5.0, 0.8), bevel=0.2)
    v1.box((9, 7, 2.8), v1.mat(PURPLE, 0.6), loc=(7.5, 5.0, 1.4), bevel=0.2)
    v1.box((8, 5, 0.9), v1.mat(PINK, 0.6), loc=(8.5, -5.5, 0.45), bevel=0.2)
    tower_at(-10.0, 6.5, 1.6, 1.0, 2.4, RUNNER)
    tower_at(9.5, 6.8, 2.8, 1.1, 2.6, HOT_PINK)
    tower_at(5.0, 7.0, 2.8, 0.8, 1.8, SKY_BLUE)
    # 青い段から手前へ下りる滑り台
    v1.box((2.0, 7.0, 0.2), v1.mat(HOT_PINK), loc=(-6.0, -1.6, 0.85), rot=(13, 0, 0), bevel=0.06)
    v1.box((0.7, 7.0, 0.22), v1.mat("#bae6fd"), loc=(-6.0, -1.6, 0.92), rot=(13, 0, 0), bevel=0.05)
    # 視線を切る黄色い壁と、ギミック（実物のモデル）
    v1.box((0.7, 4.0, 2.4), v1.mat(YELLOW), loc=(1.0, 1.5, 1.2), rot=(0, 0, 8), bevel=0.2)
    v1.box((4.0, 0.7, 2.4), v1.mat(YELLOW), loc=(-1.0, -5.8, 1.2), rot=(0, 0, -6), bevel=0.2)
    prop("boost_panel.blend", {"DashPad", "Plate", "Frame"}, loc=(3.6, -3.4, 0.0), yaw=30, scale=0.36)
    prop("spring_pad.blend", {"SpringPad", "Spring", "Pad", "Coil1", "Base.001"},
         loc=(-10.0, -5.0, 0.0), scale=0.5)
    for x, y in ((-2.6, 4.0), (11.0, -1.5), (-11.5, 0.5)):
        v1.present(x, y, 0.8)

    figs = []
    # 滑り台を滑ってくる緑。鬼は3人で、それぞれ別の方向を探している
    runner = char(RUNNER, "SlideSit", 0, loc=(-6.0, -1.4, 1.0), yaw=0, tilt=(-13, 0), scale=2.3)
    figs.append(runner)
    for loc, yaw, clip, frame in (((3.6, -0.2, 0.0), 125, "Run", 6),
                                  ((8.5, -5.2, 0.9), -40, "Idle", 0),
                                  ((5.2, 2.6, 2.8), 215, "Idle", 0)):
        hunter = char(HUNTER, clip, frame, loc=loc, yaw=yaw, scale=2.3)
        v1.horns(hunter)
        figs.append(hunter)
    ortho_camera((0.55, -1.0, 0.78), (0.4, -1.0, -3.6), 36.0)

    scene_px = render_rgba()
    base = over(base, outline(scene_px, 3.0 * s, rim=2.0 * s, drop=3.0 * s))
    # 島の下の空にタイトル（参考にした Pikuniku・Kaaarot と同じく下に置く）
    title = title_layer(int(500 * s), int(165 * s))
    base = place(base, title, 315, 405)
    finish(base, path)


# =====================================================================
# 案 D: 4対4パーティー（Team Up!）
# =====================================================================

def concept_d(path):
    s = STATE["scale"]
    # 背景: 黄色の放射（集合写真の後光）と、チーム色の紙ふぶき
    base = vertical("#fef08a", "#fde047")
    base = paint(base, "#fffbeb", rays(0.5, 0.38, 16) * 0.55)
    rng = np.random.default_rng(7)
    for _ in range(46):
        cx, cy = rng.uniform(0.02, 0.98), rng.uniform(0.05, 0.98)
        r = rng.uniform(0.006, 0.012)
        color = (TEAM_A, TEAM_B, HOT_PINK, WHITE)[rng.integers(0, 4)]
        base = paint(base, color, blob(cx, cy, r, r * W / H))

    reset_scene(ortho=True)
    # 2段のステージ。後ろの段に立つ列は少し高い
    ui.cyl(4.9, 0.35, ui.mat("#ffffff"), axis="Z", loc=(0.0, 0.5, -0.18))
    ui.box((9.0, 1.7, 0.55), ui.mat("#c4b5fd"), loc=(0.0, 1.5, 0.27), bevel=0.12)
    # 左: 青チーム（いまは逃げる番）。右: 橙チーム（いまは鬼の番なので角を付ける）
    blue = (((-2.65, -0.7, 0.0), 22, "Nice", 9, "HatParty"),
            ((-0.95, -0.9, 0.0), 12, "ComeHip", 12, "HatCap"),
            ((-3.7, 1.5, 0.55), 18, "Idle", 0, "HatPropeller"),
            ((-1.85, 1.5, 0.55), 10, "Come", 8, None))
    # 角と帽子がぶつかるので、帽子は逃げる側の青チームだけにかぶせる
    blue = blue[:3] + ((blue[3][0], blue[3][1], blue[3][2], blue[3][3], "HatCrown"),)
    orange = (((0.95, -0.9, 0.0), -12, "ComeCool", 10, None),
              ((2.65, -0.7, 0.0), -22, "Nice", 18, None),
              ((1.85, 1.5, 0.55), -10, "Come", 14, None),
              ((3.7, 1.5, 0.55), -18, "Run", 6, None))
    for team, color, horned in ((blue, TEAM_A, False), (orange, TEAM_B, True)):
        for loc, yaw, clip, frame, hat_name in team:
            rig = char(color, clip, frame, loc=loc, yaw=yaw, scale=1.0, emit=0.22)
            if horned:
                v1.horns(rig)
            if hat_name:
                hat(rig, hat_name)
    # 捕まって幽霊になった青チームの1人。バナナを掲げて、敵の鬼に当てて復活をねらう
    ghost = char(TEAM_A, "Nice", 9, loc=(-0.1, 1.9, 1.75), yaw=8, scale=0.95)
    ghostify(ghost)
    banana = prop("banana_peel.blend", {"BananaPeel", "PeelLongRight", "PeelLongLeft", "PeelFlapRight",
                                         "PeelFlapLeft", "Core"}, loc=(0.75, 1.6, 2.95), yaw=25, scale=0.9)
    banana.rotation_euler = Euler((math.radians(-20), math.radians(25), math.radians(25)), "XYZ")
    # ステージの下の縁は画面の外へ出して、そのぶんキャラを大きく見せる
    art = shoot_box(int(720 * s), int(410 * s), yaw=0.0, pitch=9.0, bare=objects_of(ghost))
    base = place(base, art, 315, 338)

    title = title_layer(int(500 * s), int(160 * s))
    base = place(base, title, 315, 88)
    finish(base, path)


CONCEPTS = {
    "a": ("cover_v2a_close_call.png", concept_a),
    "b": ("cover_v2b_reverse.png", concept_b),
    "c": ("cover_v2c_playground.png", concept_c),
    "d": ("cover_v2d_team_up.png", concept_d),
}


def make_sheet(out_dir, names):
    """比較用の一覧。上に原寸（630x500）を2x2、下に itch.io の最小（315x250）を4つ並べる。
    小さく縮めてもタイトルとキャラが分かるかを見るため（ui_art_sheet.png と同じ考え方）。"""
    gap = 12
    imgs = [ui._load_pixels(os.path.join(out_dir, CONCEPTS[n][0]))[..., :3] for n in names]
    smalls = [im.reshape(H // 2, 2, W // 2, 2, 3).mean(axis=(1, 3)) for im in imgs]
    sw = 2 * W + 3 * gap
    sh = 2 * H + H // 2 + 4 * gap
    sheet = np.broadcast_to(rgb("#f1f5f9"), (sh, sw, 3)).copy()
    # 配列は下の行から上へ並ぶので、上段の行ほど y が大きい
    for i, im in enumerate(imgs):
        col, row = i % 2, i // 2
        x = gap + col * (W + gap)
        y = sh - gap - (row + 1) * H - row * gap
        sheet[y:y + H, x:x + W] = im
    for i, im in enumerate(smalls):
        x = gap + i * (W // 2)
        sheet[gap:gap + H // 2, x:x + W // 2] = im
    path = os.path.join(out_dir, "cover_v2_sheet.png")
    ui._save_pixels(path, np.dstack([sheet, np.ones(sheet.shape[:2], dtype=np.float32)]))
    print("sheet  :", path, sw, "x", sh)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out_dir = os.path.abspath(args[0]) if args and not args[0].startswith("--") else os.path.join(
        os.path.dirname(os.path.dirname(HERE)), "docs", "concept", "store", "cover_image")
    if "--scale" in args:
        STATE["scale"] = int(args[args.index("--scale") + 1])
    if "--draft" in args:
        STATE["draft"] = True
        STATE["scale"] = 1
    names = list(CONCEPTS)
    if "--only" in args:
        names = args[args.index("--only") + 1].split(",")
    os.makedirs(out_dir, exist_ok=True)
    if "--sheet-only" not in args:
        for name in names:
            filename, fn = CONCEPTS[name]
            fn(os.path.join(out_dir, filename))
    if "--sheet" in args or "--sheet-only" in args:
        make_sheet(out_dir, list(CONCEPTS))


if __name__ == "__main__":
    main()
