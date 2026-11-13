"""ストアのカバー画像の別案（KAN-87）を、ゲームと同じキャラのモデルから Blender で描いて PNG に書き出す。

    blender -b -P tools/blender/build_cover_concepts.py -- <出力ディレクトリ> [--only a,b] [--scale 2] [--draft] [--sheet]

案は4つで、どれも 630x500（itch.io のカバー）に「REVERSE TAG!」とゲームのキャラ（きょうりゅう）を入れる。
各案のねらいは docs/concept/store/cover_image/CONCEPTS.md。

    a  つかまる寸前    低いカメラで、逃げる緑のすぐ後ろへ角の赤が飛びつく一瞬
    b  逆転            赤と緑に斜めに分けた背景で、入れ替わりの矢印の輪の中に背中合わせの2人
    c  遊び場ジオラマ  空に浮かぶ島のマップを見下ろし、滑り台の緑と探し回る赤
    d  4対4パーティー  Reverse Tag モードの青と橙の2チームが、帽子をかぶって並ぶ集合写真

作風を変えた追加の案（KAN-89）。文字は作風に合わせて tools/blender/fonts/ の OFL フォントで描く:

    e  ドット絵          横から見たチェイスを 126x100 で描いて減色し、ドットのまま拡大
    f  80年代アーケード  夕焼けの横縞の太陽とネオンの格子の床、クロームとネオンの文字
    g  今風ミニマル      広い余白に走る緑1人と長い影、画面の右端から鬼の手と角だけ
    h  近代の広告ポスター  扇形の後光と額縁、少ない色のベタ塗り、金のアール・デコ文字
    i  疾走感            傾けた広角、放射状にぼかした背景と速度線、残像の付いた斜体の文字

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


def outline(px, thickness, rim=None, drop=None, ink_hex=ui.PURPLE, rim_hex=WHITE):
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
    out_rgb = np.broadcast_to(rgb(rim_hex), color.shape).copy()
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


def render_rgba(keep=None, size=None):
    """今のカメラで透明背景のまま描いて、RGBA の配列で返す。keep を渡すとそれ以外を隠す。
    size を渡すとその画素数で描く（既定はキャンバスの大きさ）。"""
    scene = bpy.context.scene
    hidden = []
    if keep is not None:
        keep = set(keep)
        for obj in scene.objects:
            if obj.type in {"MESH", "CURVE", "FONT"} and obj not in keep and not obj.hide_render:
                obj.hide_render = True
                hidden.append(obj)
    w, h = size or canvas_size()
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


# =====================================================================
# 作風を変えた案（E〜I、KAN-89）の共通部品
# 文字は作風に合わせて、tools/blender/fonts/ の OFL フォントで描く（README 参照。製品には入らない）
# =====================================================================

FONT_DIR = os.path.join(HERE, "fonts")
FONT_PIXEL = os.path.join(FONT_DIR, "PressStart2P-Regular.ttf")
FONT_LIGHT = os.path.join(FONT_DIR, "Poppins-Light.ttf")
FONT_BOLD_ITALIC = os.path.join(FONT_DIR, "Poppins-ExtraBoldItalic.ttf")
FONT_BLACK_ITALIC = os.path.join(FONT_DIR, "Poppins-BlackItalic.ttf")
FONT_DECO = os.path.join(FONT_DIR, "Limelight-Regular.ttf")


def blend_over(dst, src):
    """RGBA の src を RGBA の dst の上へ（同じ大きさ）。"""
    c, a = ui._over(dst[..., :3], dst[..., 3], src[..., :3], src[..., 3])
    return np.dstack([c, a])


def solid(mask, hex_color, alpha=1.0):
    return np.dstack([np.broadcast_to(rgb(hex_color), mask.shape + (3,)), mask * alpha])


def stops_color(t, stops):
    """t（0〜1 の配列）を、[(位置, 色), ...] のグラデーションの色へ。"""
    pos = np.array([p for p, _ in stops], dtype=np.float32)
    cols = np.array([rgb(c) for _, c in stops], dtype=np.float32)
    out = np.empty(t.shape + (3,), dtype=np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, pos, cols[:, ch])
    return out


def vstops(stops):
    """キャンバス全体の縦のグラデーション。stops の位置は y（下が 0、上が 1）。"""
    _, y = grid()
    return stops_color(y, stops)


def gradient_fill(mask, stops):
    """文字の形の中を、文字の上端（0）から下端（1）への縦のグラデーションで塗る。"""
    rows = np.nonzero(mask.max(axis=1) > 0.5)[0]
    top, bottom = rows.max(), rows.min()  # 配列は下の行から並ぶので、上端の方が添字が大きい
    idx = np.arange(mask.shape[0], dtype=np.float32)
    t = np.clip((top - idx) / max(top - bottom, 1), 0.0, 1.0)
    color = stops_color(np.broadcast_to(t[:, None], mask.shape), stops)
    return np.dstack([color, mask])


def blur(a, r):
    """箱型のぼかしを3回（ほぼガウス）。r は画素数。"""
    r = max(int(r), 1)
    out = a.astype(np.float32)
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0)] * out.ndim
            pad[axis] = (r + 1, r)
            c = np.cumsum(np.pad(out, pad, mode="edge"), axis=axis, dtype=np.float64)
            hi = np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
            lo = np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)
            out = ((hi - lo) / (2 * r + 1)).astype(np.float32)
    return out


def glow(mask, radius, hex_color, strength=1.0):
    """形の周りへにじむ光（ネオン）。"""
    a = np.clip(blur(ui._dilate(mask, radius * 0.3), radius) * strength, 0.0, 1.0)
    return solid(a, hex_color)


def shift(layer, dx, dy):
    """RGBA を画素単位でずらす（はみ出た分は捨てる）。dy は上が正。"""
    out = np.zeros_like(layer)
    h, w = layer.shape[:2]
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    out[yd, xd] = layer[ys, xs]
    return out


def smear(layer, dx, dy, n, colors):
    """layer の後ろへ、(dx, dy) 方向へ伸びる残像を n 枚敷く。colors は手前から奥への色。"""
    out = np.zeros_like(layer)
    for i in range(n, 0, -1):
        t = i / n
        ghost = shift(layer, int(round(dx * t)), int(round(dy * t)))
        c = stops_color(np.full(ghost.shape[:2], t, dtype=np.float32),
                        [(k / (len(colors) - 1), col) for k, col in enumerate(colors)])
        out = blend_over(out, np.dstack([c, ghost[..., 3] * (1.0 - t) * 0.85]))
    return blend_over(out, layer)


def quantize(color, palette):
    """各画素を、palette の中で最も近い色に置き換える（ドット絵・ポスターの限られた色）。"""
    pal = np.array([rgb(c) for c in palette], dtype=np.float32)
    flat = color.reshape(-1, 3)
    best = np.empty(flat.shape[0], dtype=np.int64)
    step = 200000
    for i in range(0, flat.shape[0], step):
        d = ((flat[i:i + step, None, :] - pal[None]) ** 2).sum(-1)
        best[i:i + step] = d.argmin(-1)
    return pal[best].reshape(color.shape)


def radial_blur(px, cx, cy, amount, steps=14):
    """(cx, cy)（0〜1、y は上が 1）へ向かう放射状のぼかし。px は RGBA（乗算済みにして平均する）。"""
    h, w = px.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    ox, oy = cx * (w - 1), cy * (h - 1)
    pre = np.dstack([px[..., :3] * px[..., 3:4], px[..., 3:4]])
    acc = np.zeros_like(pre)
    for i in range(steps):
        k = 1.0 - amount * i / (steps - 1)
        sx = np.clip(np.round(ox + (xs - ox) * k), 0, w - 1).astype(np.int64)
        sy = np.clip(np.round(oy + (ys - oy) * k), 0, h - 1).astype(np.int64)
        acc += pre[sy, sx]
    acc /= steps
    a = acc[..., 3:4]
    return np.dstack([acc[..., :3] / np.maximum(a, 1e-6), a])


def text_obj(text, font_path, size):
    """平らな1行の文字。正面（-Y）を向けて立て、白く光らせる（形だけを取り出すため）。"""
    curve = bpy.data.curves.new("Txt", "FONT")
    curve.body = text
    curve.font = bpy.data.fonts.load(font_path, check_existing=True)
    curve.size = size
    curve.align_x = "LEFT"
    curve.align_y = "BOTTOM_BASELINE"
    obj = bpy.data.objects.new("Txt_" + text, curve)
    bpy.context.scene.collection.objects.link(obj)
    obj.rotation_euler = Euler((math.radians(90), 0, 0), "XYZ")
    m = bpy.data.materials.new("TxtMask")
    m.use_nodes = True
    nodes = m.node_tree.nodes
    nodes.clear()
    em = nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1, 1, 1, 1)
    out = nodes.new("ShaderNodeOutputMaterial")
    m.node_tree.links.new(em.outputs[0], out.inputs[0])
    curve.materials.append(m)
    return obj


def text_masks(rows, width, height, rot=0.0, align="CENTER", row_gap=0.18):
    """文字の形（アルファ）を、width x height 画素の箱に収めて描く。

    rows は行の並び（上から）で、各行は [(文字, フォント, 大きさ), ...]。同じ行の語は
    空白を空けて横に並べる。返り値は語ごとのアルファ（同じ箱・同じカメラ）で、語ごとに
    別の色で塗れる。rot は箱の中での傾き（度、正で反時計回り）。"""
    reset_scene(ortho=True)
    scene = bpy.context.scene
    pivot = bpy.data.objects.new("TxtPivot", None)
    scene.collection.objects.link(pivot)
    words, z = [], 0.0
    for row in rows:
        objs = [text_obj(t, f, s) for t, f, s in row]
        bpy.context.view_layer.update()
        height_row = max(s for _, _, s in row)
        space = 0.28 * height_row
        widths = [o.dimensions.x for o in objs]
        total = sum(widths) + space * (len(objs) - 1)
        x = -total / 2.0 if align == "CENTER" else 0.0
        z -= height_row * 0.75
        for o, wdt in zip(objs, widths):
            o.location = (x, 0.0, z)
            o.parent = pivot
            x += wdt + space
        z -= height_row * row_gap
        words.extend(objs)
    pivot.rotation_euler = Euler((0.0, math.radians(-rot), 0.0), "XYZ")
    bpy.context.view_layer.update()
    ui._fit_camera(width, height, 0.0, 0.0)
    ss = ui.SUPERSAMPLE
    scene.render.resolution_x = width * ss
    scene.render.resolution_y = height * ss
    scene.render.resolution_percentage = 100
    tmp = os.path.join(tempfile.gettempdir(), "cover_concept_text.png")
    scene.render.filepath = tmp
    masks = []
    for target in words:
        for o in words:
            o.hide_render = o is not target
        bpy.ops.render.render(write_still=True)
        a = ui._load_pixels(tmp)[..., 3]
        masks.append(a.reshape(height, ss, width, ss).mean(axis=(1, 3)))
    return masks


def pixel_text(text):
    """Press Start 2P の文字を、フォントの1ドット＝1画素のビットマップ（0/1）で返す。
    8 倍で描いてから 8x8 ごとにまとめるので、ドットの格子がずれない。"""
    reset_scene(ortho=True)
    scene = bpy.context.scene
    obj = text_obj(text, FONT_PIXEL, 8.0)  # このフォントは em が 8 ドットなので、1ドット＝1.0
    bpy.context.view_layer.update()
    corners = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    x0, x1 = min(c.x for c in corners), max(c.x for c in corners)
    z0, z1 = min(c.z for c in corners), max(c.z for c in corners)
    wu, hu = (x1 - x0) + 4.0, (z1 - z0) + 4.0
    cam = scene.camera
    cam.data.ortho_scale = max(wu, hu)
    cam.location = ((x0 + x1) / 2.0, -20.0, (z0 + z1) / 2.0)
    cam.rotation_euler = Euler((math.radians(90), 0, 0), "XYZ")
    cam.data.clip_start, cam.data.clip_end = 0.1, 100.0
    k = 8
    scene.render.resolution_x = int(round(wu * k))
    scene.render.resolution_y = int(round(hu * k))
    scene.render.resolution_percentage = 100
    tmp = os.path.join(tempfile.gettempdir(), "cover_concept_pixel_text.png")
    scene.render.filepath = tmp
    bpy.ops.render.render(write_still=True)
    a = ui._load_pixels(tmp)[..., 3]
    ys, xs = np.nonzero(a > 0.5)
    a = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = (a.shape[0] + k // 2) // k, (a.shape[1] + k // 2) // k
    a = np.pad(a, ((0, h * k - a.shape[0] if h * k > a.shape[0] else 0),
                   (0, w * k - a.shape[1] if w * k > a.shape[1] else 0)))[:h * k, :w * k]
    return (a.reshape(h, k, w, k).mean(axis=(1, 3)) > 0.5).astype(np.float32)


def screen_xy(point):
    """3D の点が、今のカメラの画面のどこに映るか（0〜1、y は上が 1）。"""
    from bpy_extras.object_utils import world_to_camera_view
    scene = bpy.context.scene
    # カメラを置いた直後は matrix_world がまだ古いので、先に更新する（しないと位置が大きくずれる）
    # 投影は解像度の縦横比で変わるので、描くときと同じ大きさにしておく
    w, h = canvas_size()
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.resolution_percentage = 100
    bpy.context.view_layer.update()
    co = world_to_camera_view(scene, scene.camera, Vector(point))
    return co.x, co.y


def lowest_point(rig):
    """キャラの一番低い点（ワールド座標）。走りのポーズは体が浮くので、足元の影の位置に使う。"""
    dg = bpy.context.evaluated_depsgraph_get()
    best = None
    for obj in rig.children_recursive:
        if obj.type != "MESH":
            continue
        ev = obj.evaluated_get(dg)
        mesh = ev.to_mesh()
        for v in mesh.vertices:
            w = ev.matrix_world @ v.co
            if best is None or w.z < best.z:
                best = w.copy()
        ev.to_mesh_clear()
    return best


def add_sun(name, energy, rot, color_hex=WHITE, shadow=False, angle=6.0):
    light = bpy.data.lights.new(name, "SUN")
    light.energy = energy
    light.color = v1.srgb(color_hex)
    light.use_shadow = shadow
    light.angle = math.radians(angle)
    obj = bpy.data.objects.new(name, light)
    obj.rotation_euler = Euler([math.radians(a) for a in rot], "XYZ")
    bpy.context.scene.collection.objects.link(obj)
    return obj


def place_layer(base, layer, cx, cy):
    """RGBA の layer の中心を、仕上がり座標 (cx, cy)（左上原点）へ置く（place の別名。読みやすさのため）。"""
    return place(base, layer, cx, cy)


def finish_exact(rgb_full, path):
    """すでに 630x500 の絵をそのまま保存する（ドット絵用。縮めると点がぼやけるため）。"""
    ui._save_pixels(path, np.dstack([rgb_full, np.ones(rgb_full.shape[:2], dtype=np.float32)]))
    print("render :", path, rgb_full.shape[1], "x", rgb_full.shape[0])


# =====================================================================
# 案 E: ドット絵（Pixel）
# =====================================================================

PIX = 5                          # 1ドットを何画素にするか
LW, LH = W // PIX, H // PIX      # ドットの画面は 126x100
PIXEL_PALETTE = [
    "#1e1b4b", "#ffffff", "#e2e8f0", "#94a3b8",
    "#bfdbfe", "#93c5fd", "#60a5fa",
    "#86efac", "#22c55e", "#15803d",
    "#fca5a5", "#ef4444", "#991b1b",
    "#fde68a", "#facc15", "#ca8a04", "#fb923c",
    "#a3e635", "#4d7c0f", "#b45309", "#78350f",
    "#a78bfa", "#6d28d9", "#f472b6",
]


def concept_e(path):
    # ---- 3D（横スクロールの横からの眺め）を 4 倍で描き、ドットの大きさへまとめる ----
    reset_scene()
    v1.box((40, 2.4, 0.3), v1.mat(LIME, 0.6), loc=(0, 0, -0.15), bevel=0.0)
    v1.box((40, 2.4, 2.5), v1.mat("#b45309", 0.8), loc=(0, 0, -1.55), bevel=0.0)
    # 奥の段丘と塔は小さく、タイトルにかからない左右の端へ
    v1.box((2.2, 2.0, 0.7), v1.mat(SKY_BLUE, 0.6), loc=(-2.9, 5.0, 0.35), bevel=0.05)
    v1.box((2.2, 2.0, 1.0), v1.mat(PURPLE, 0.6), loc=(2.9, 6.0, 0.5), bevel=0.05)
    tower_at(-3.2, 5.0, 0.7, 0.28, 0.5, RUNNER)
    tower_at(3.1, 6.0, 1.0, 0.26, 0.45, HOT_PINK)
    v1.present(2.75, -0.6, 0.42)
    v1.present(-3.0, -0.4, 0.36)
    # 真横だと顔が見えないので、少しこちらへ向ける
    runner = char(RUNNER, "Run", 0, loc=(1.05, 0.0, 0.0), yaw=62, scale=1.0)
    hunter = char(HUNTER, "Dive", 22, loc=(-1.15, 0.0, 0.42), yaw=66, tilt=(38, 0), scale=1.0)
    v1.horns(hunter)
    ortho_camera((0.0, -1.0, 0.16), (0.0, 0.0, 1.62), 6.8)
    big = render_rgba(size=(LW * 4, LH * 4))
    blocks = big.reshape(LH, 4, LW, 4, 4)
    a = blocks[..., 3].mean(axis=(1, 3))
    c = (blocks[..., :3] * blocks[..., 3:4]).sum(axis=(1, 3)) / np.maximum(blocks[..., 3].sum(axis=(1, 3)), 1e-6)[..., None]
    sprite_a = (a > 0.5).astype(np.float32)
    sprite = quantize(c, PIXEL_PALETTE)

    # キャラだけの形（1ドットの濃いふちを付けるため）
    chars_big = render_rgba(keep=objects_of(runner) + objects_of(hunter), size=(LW * 4, LH * 4))
    chars_a = (chars_big[..., 3].reshape(LH, 4, LW, 4).mean(axis=(1, 3)) > 0.5).astype(np.float32)

    # ---- 2D（ドットの空と雲） ----
    ys, xs = np.mgrid[0:LH, 0:LW]
    sky = np.empty((LH, LW, 3), dtype=np.float32)
    checker = (xs + ys) % 2 == 0
    bands = [(78, "#60a5fa", None), (70, "#60a5fa", "#93c5fd"), (56, "#93c5fd", None),
             (48, "#93c5fd", "#bfdbfe"), (0, "#bfdbfe", None)]
    for low, col, dither in reversed(bands):
        sel = ys >= low
        sky[sel] = rgb(col)
        if dither:
            sky[sel & checker] = rgb(dither)
    for cx, cy, r in ((14, 68, 6), (21, 70, 8), (28, 67, 5), (98, 74, 6), (106, 76, 8), (113, 73, 5)):
        d = ((xs - cx) / r) ** 2 + ((ys - cy) / (r * 0.6)) ** 2
        sky[d <= 1.0] = rgb(WHITE)
        sky[(d <= 1.0) & (ys < cy - r * 0.25)] = rgb("#e2e8f0")
    img = np.where(sprite_a[..., None] > 0, sprite, sky)
    # 土の面にレンガ風の点々（ドット絵の地面らしく）
    dirt = np.all(np.abs(img - rgb("#b45309")) < 1e-3, axis=-1)
    brick = ((ys % 4 == 0) | (((xs + (ys // 4) * 3) % 8) == 0))
    img[dirt & brick] = rgb("#78350f")

    # キャラに1ドットの濃いふち（上下左右）
    ring = np.zeros_like(chars_a)
    ring[1:, :] = np.maximum(ring[1:, :], chars_a[:-1, :])
    ring[:-1, :] = np.maximum(ring[:-1, :], chars_a[1:, :])
    ring[:, 1:] = np.maximum(ring[:, 1:], chars_a[:, :-1])
    ring[:, :-1] = np.maximum(ring[:, :-1], chars_a[:, 1:])
    ring = ring * (1.0 - chars_a)
    img[ring > 0] = rgb("#1e1b4b")

    # ---- タイトル（Press Start 2P、ドットのまま） ----
    def stamp(bitmap, scale, top, face, shade, shade_rows, ring=True):
        """ドット文字を、上から top ドットの位置へ中央ぞろえで押す。1ドットの濃いふちと、
        右下へ1ドットずらした影を付け、文字の下の数行を濃い色にして厚みを出す。"""
        bm = np.kron(bitmap, np.ones((scale, scale), dtype=np.float32))
        h, w = bm.shape
        x0 = (LW - w) // 2
        y0 = LH - top - h  # 配列は下の行から並ぶので、下端の行の添字
        m = np.zeros((LH, LW), dtype=np.float32)
        m[y0:y0 + h, x0:x0 + w] = bm
        edge = m.copy()
        # 小さい文字は、ふちを回すと字のすき間（E の腕の間など）が埋まって読めなくなるので影だけにする
        for dy, dx in (((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)) if ring else ()):
            edge = np.maximum(edge, np.roll(np.roll(m, dy, 0), dx, 1))
        shadow = np.roll(np.roll(edge, -1, 0), 1, 1)  # 右下へ1ドット（下は添字が小さい方）
        img[np.maximum(edge, shadow) > 0] = rgb("#1e1b4b")
        face_rgb = np.broadcast_to(rgb(face), (LH, LW, 3)).copy()
        face_rgb[y0:y0 + shade_rows] = rgb(shade)
        img[m > 0] = face_rgb[m > 0]

    stamp(pixel_text("REVERSE"), 2, 6, "#ef4444", "#991b1b", 2, ring=False)
    stamp(pixel_text("TAG!"), 3, 26, "#facc15", "#fb923c", 6)

    full = np.repeat(np.repeat(img, PIX, axis=0), PIX, axis=1)
    finish_exact(full, path)


# =====================================================================
# 案 F: 80年代アーケード（Arcade Sunset）
# =====================================================================

def chrome_title(width, height, rot=-6.0):
    """「REVERSE」をクロームの金属、「TAG!」をピンクのネオンで。"""
    rev, tag = text_masks([[("REVERSE", FONT_BOLD_ITALIC, 1.0)], [("TAG!", FONT_BLACK_ITALIC, 1.35)]],
                          width, height, rot=rot, row_gap=0.05)
    s = STATE["scale"]
    layer = np.zeros(rev.shape + (4,), dtype=np.float32)
    layer = blend_over(layer, glow(np.maximum(rev, tag), 10 * s, "#ec4899", 0.9))
    ink = ui._dilate(rev, 3.0 * s)
    layer = blend_over(layer, solid(ui._dilate(ink, 1.5 * s), "#fdf2f8"))
    layer = blend_over(layer, solid(ink, "#1e1b4b"))
    layer = blend_over(layer, gradient_fill(rev, [(0.0, "#e0f2fe"), (0.44, "#38bdf8"), (0.5, "#ffffff"),
                                                  (0.53, "#7c2d12"), (0.78, "#f59e0b"), (1.0, "#fef3c7")]))
    tag_ink = ui._dilate(tag, 3.0 * s)
    layer = blend_over(layer, solid(tag_ink, "#4a044e"))
    layer = blend_over(layer, gradient_fill(tag, [(0.0, "#ffe4f6"), (0.3, "#ff4fd8"), (1.0, "#c026d3")]))
    return layer


def concept_f(path):
    s = STATE["scale"]
    # 先に 3D を組み、カメラの地平線の高さを測ってから背景を描く（2D の床と 3D のキャラの足元を揃えるため）
    reset_scene()
    add_sun("RimPink", 5.0, (-60, 0, -150), "#f472b6")
    add_sun("RimCyan", 5.0, (-60, 0, 150), "#22d3ee")
    runner = char(RUNNER, "Run", 0, loc=(0.8, -0.4, 0.0), yaw=-20, scale=1.0)
    hunter = char(HUNTER, "Dive", 22, loc=(-0.9, 1.3, 0.55), yaw=-8, tilt=(34, 0), scale=1.0)
    v1.horns(hunter)
    perspective_camera((0.0, -6.4, 0.9), (0.0, 1.0, 1.55), 32)
    _, hz = screen_xy((0.0, 2000.0, 0.9))  # カメラと同じ高さの遠い点＝地平線
    foot = lowest_point(runner)
    shadows = [screen_xy((0.8, -0.4, foot.z)), screen_xy((-0.9, 1.3, 0.0))]
    chars = render_rgba()
    del runner

    x, y = grid()
    aspect = W / H
    base = vstops([(0.0, "#3b0764"), (hz, "#fb923c"), (hz + 0.2, "#f472b6"), (hz + 0.42, "#a21caf"), (1.0, "#4c1d95")])
    # 横縞の太陽（夕方。夜景にはしない）
    sun_r = 0.2
    d = np.sqrt(((x - 0.5) * aspect) ** 2 + (y - (hz + 0.02)) ** 2) / (sun_r * aspect)
    sun = (1.0 - smooth(0.99, 1.01, d)) * (y > hz)
    gap = (y - hz) / (sun_r * aspect)
    stripes = (np.sin(gap * 46.0) > (0.3 - gap * 1.6)) | (gap > 0.55)
    sun_col = stops_color(np.clip(gap, 0, 1), [(0.0, "#f472b6"), (0.5, "#fb923c"), (1.0, "#fde047")])
    m = (sun * stripes)[..., None]
    base = base * (1 - m) + sun_col * m
    # 地平線の山並み（遠景の紫。太陽の前は低くする）
    ridge = hz + 0.035 + 0.03 * np.abs(np.sin(x * 9.0)) + 0.02 * np.abs(np.sin(x * 23.0 + 1.0))
    ridge = np.where(np.abs(x - 0.5) < 0.22, hz + 0.006, ridge)
    base = paint(base, "#581c87", ((y >= hz) & (y < ridge)).astype(np.float32))
    # 地平線へ伸びる格子の床（奥行き 1/v の等間隔の横線と、消失点へ集まる縦線）
    floor = (y < hz).astype(np.float32)
    v = np.maximum(hz - y, 1e-3)
    depth = 1.0 / v
    lx = (x - 0.5) * aspect / v

    def lines(coord, period, width_px):
        g = np.abs(np.gradient(coord, axis=1)) + np.abs(np.gradient(coord, axis=0)) + 1e-6
        dist = np.abs(((coord / period + 0.5) % 1.0) - 0.5) * period / g
        return 1.0 - smooth(width_px * 0.5, width_px, dist)

    grid_m = np.maximum(lines(depth, 1.2, 1.8 * s), lines(lx, 0.45, 1.8 * s)) * floor
    grid_m *= smooth(0.0, 0.035, hz - y)  # 地平線の際は線が詰まりすぎるので消す
    base = paint(base, "#2e1065", floor * 0.9)
    base = over(base, glow(grid_m, 5 * s, "#e879f9", 0.7))
    base = paint(base, "#f5d0fe", grid_m)
    # 地平線の光る線
    base = paint(base, "#fdf4ff", 1.0 - smooth(0.0015, 0.004, np.abs(y - hz)))

    for fx, fy in shadows:
        base = paint(base, "#1e1b4b", blob(fx, fy, 0.06, 0.022) * 0.6)
    base = over(base, outline(chars, 3.0 * s, rim=2.0 * s, drop=0.0, ink_hex="#1e1b4b", rim_hex="#f9a8d4"))

    title = chrome_title(int(580 * s), int(200 * s))
    base = place(base, title, 315, 100)
    finish(base, path)


# =====================================================================
# 案 G: 今風ミニマル（Minimal）
# =====================================================================

def concept_g(path):
    s = STATE["scale"]
    reset_scene()
    scene = bpy.context.scene
    # 光は低い太陽1つ。長くやわらかい影で「走っている」を見せる
    for obj in list(scene.objects):
        if obj.type == "LIGHT":
            bpy.data.objects.remove(obj)
    add_sun("Low", 3.4, (72, 0, -62), shadow=True, angle=4.0)
    add_sun("Soft", 0.5, (40, 0, 60))
    v1.box((90, 90, 0.2), v1.mat("#ece6da", 0.95), loc=(0, 10, -0.1), bevel=0.0)
    runner = char(RUNNER, "Run", 6, loc=(-0.55, 0.6, 0.0), yaw=48, scale=1.0)
    # 右の画面の外から、鬼の手と角だけがのぞく
    hunter = char(HUNTER, "Dive", 22, loc=(3.4, 0.2, 0.55), yaw=-72, tilt=(30, 0), scale=1.0)
    v1.horns(hunter)
    perspective_camera((0.4, -7.6, 4.4), (0.4, 0.5, 0.5), 50)
    del runner, hunter
    base = render_rgba()[..., :3]

    rev, tag = text_masks([[("REVERSE", FONT_LIGHT, 1.0), ("TAG!", FONT_LIGHT, 1.0)]], int(380 * s), int(52 * s))
    layer = np.zeros(rev.shape + (4,), dtype=np.float32)
    layer = blend_over(layer, solid(rev, "#1f2937"))
    layer = blend_over(layer, solid(tag, "#dc2626"))
    # 左上にそろえて置く（雑誌の見出しのような余白の取り方）
    lh, lw = layer.shape[:2]
    x0, y0 = px(36, 36)
    base = over(base, layer, x0 - int(0.05 * lw), y0 - lh + int(0.12 * lh))
    # 見出しの下の細い線
    xa, ya = px(46, 92)
    base[ya - s:ya + s, xa:xa + int(64 * s)] = rgb("#dc2626")
    finish(base, path)


# =====================================================================
# 案 H: 近代の広告ポスター（Art Deco Poster）
# =====================================================================

POSTER_PALETTE = ["#1c1917", "#efe3c8", "#fffaf0", "#dc2626", "#7f1d1d", "#16a34a", "#14532d",
                  "#d4a537", "#8a6d1c", "#0f766e"]


def concept_h(path):
    s = STATE["scale"]
    x, y = grid()
    aspect = W / H
    base = np.broadcast_to(rgb("#efe3c8"), x.shape + (3,)).copy()
    # 扇形の後光（アール・デコ）。下の中央から、青緑と生成りを交互に
    cx, cy = 0.5, 0.2
    r = np.sqrt(((x - cx) * aspect) ** 2 + (y - cy) ** 2)
    fan = (r < 0.72) & (y > cy)
    base = paint(base, "#0f766e", (rays(cx, cy, 18) * fan).astype(np.float32))
    base = paint(base, "#d4a537", ((np.abs(r - 0.74) < 0.012) & (y > cy)).astype(np.float32))
    base = paint(base, "#1c1917", ((np.abs(r - 0.765) < 0.005) & (y > cy)).astype(np.float32))
    # 地面の帯（深紅）と金の線
    base = paint(base, "#7f1d1d", (y < cy).astype(np.float32))
    base = paint(base, "#d4a537", (np.abs(y - cy) < 0.006).astype(np.float32))

    # キャラ: 後ろに大きく身を乗り出す鬼、手前を走る緑。少ない色に減らしてベタ塗りに
    reset_scene()
    hunter = char(HUNTER, "Dive", 22, loc=(0.35, 2.2, 1.05), yaw=-14, tilt=(26, 0), scale=1.85)
    v1.horns(hunter)
    runner = char(RUNNER, "Run", 0, loc=(-0.55, -0.4, 0.0), yaw=-38, scale=1.0)
    perspective_camera((0.0, -6.8, 0.55), (0.0, 1.0, 2.15), 30)
    chars = render_rgba()
    flat = quantize(chars[..., :3], POSTER_PALETTE)
    chars = np.dstack([flat, (chars[..., 3] > 0.5).astype(np.float32)])
    base = over(base, outline(chars, 2.5 * s, rim=0.0, drop=0.0, ink_hex="#1c1917"))
    del runner

    # 額縁（黒の太線と金の細線、四隅に段の飾り）
    w2, h2 = canvas_size()
    def rect_line(inset, thick, col):
        i, t = int(inset * s), int(thick * s)
        base[i:i + t, i:w2 - i] = rgb(col)
        base[h2 - i - t:h2 - i, i:w2 - i] = rgb(col)
        base[i:h2 - i, i:i + t] = rgb(col)
        base[i:h2 - i, w2 - i - t:w2 - i] = rgb(col)
    rect_line(0, 12, "#1c1917")
    rect_line(18, 3, "#d4a537")
    for cxp, cyp in ((0, 0), (1, 0), (0, 1), (1, 1)):
        for k, size in enumerate((34, 24, 14)):
            col = ("#1c1917", "#d4a537", "#1c1917")[k]
            sz = int(size * s)
            xa = int(12 * s) if cxp == 0 else w2 - int(12 * s) - sz
            ya = int(12 * s) if cyp == 0 else h2 - int(12 * s) - sz
            base[ya:ya + sz, xa:xa + sz] = rgb(col)

    # タイトル（Limelight を金に、黒のふちと深紅の影）
    # 昔の広告ポスターのように、題は下の帯に1行で
    rev, tag = text_masks([[("REVERSE", FONT_DECO, 1.0), ("TAG!", FONT_DECO, 1.0)]],
                          int(520 * s), int(92 * s))
    letters = np.maximum(rev, tag)
    layer = np.zeros(letters.shape + (4,), dtype=np.float32)
    layer = blend_over(layer, shift(solid(ui._dilate(letters, 2.0 * s), "#7f1d1d"), int(5 * s), int(-5 * s)))
    layer = blend_over(layer, solid(ui._dilate(letters, 2.0 * s), "#1c1917"))
    layer = blend_over(layer, gradient_fill(letters, [(0.0, "#f3d27a"), (0.55, "#d4a537"), (1.0, "#8a6d1c")]))
    base = place(base, layer, 315, 444)

    # 紙のざらつき
    rng = np.random.default_rng(11)
    base = np.clip(base + rng.normal(0.0, 0.022, base.shape[:2])[..., None], 0.0, 1.0)
    finish(base, path)


# =====================================================================
# 案 I: 疾走感（Full Speed）
# =====================================================================

def roll_camera(cam, degrees):
    """カメラを視線の軸まわりに傾ける（ダッチアングル）。"""
    from mathutils import Quaternion
    q = cam.rotation_euler.to_quaternion() @ Quaternion((0.0, 0.0, 1.0), math.radians(degrees))
    cam.rotation_euler = q.to_euler()


def concept_i(path):
    s = STATE["scale"]
    base = vstops([(0.0, "#bae6fd"), (0.6, "#38bdf8"), (1.0, "#0ea5e9")])

    reset_scene()
    v1.box((140, 90, 1), v1.mat(LIME, 0.6), loc=(0, 30, -0.5), bevel=0.0)
    backdrop_map(y0=16.0)
    v1.present(-3.5, 6.0)
    v1.present(4.2, 9.0)
    pad = prop("boost_panel.blend", {"DashPad", "Plate", "Frame", "Spark0", "Spark1", "Spark2"},
               loc=(0.35, 0.9, 0.0), yaw=-25, scale=0.34)
    runner = char(RUNNER, "Run", 0, loc=(0.35, 0.7, 0.0), yaw=-22, tilt=(14, 0), scale=1.0)
    hunter = char(HUNTER, "Dive", 22, loc=(1.55, 2.3, 0.6), yaw=-25, tilt=(34, 0), scale=1.0)
    v1.horns(hunter)
    hunter2 = char(HUNTER, "Run", 6, loc=(-1.25, 3.0, 0.0), yaw=-5, tilt=(10, 0), scale=1.0)
    v1.horns(hunter2)
    cam = perspective_camera((-0.2, -2.7, 0.4), (0.4, 1.5, 1.2), 20)
    roll_camera(cam, -16.0)
    near = objects_of(runner) + objects_of(hunter) + objects_of(hunter2) + [pad] + list(pad.children_recursive)
    vx, vy = screen_xy((1.2, 40.0, 1.0))  # 奥へ向かう消失点

    far = render_rgba(keep=[o for o in bpy.context.scene.objects if o not in set(near)])
    base = paint(base, WHITE, streaks(vx, vy, 60, 0.0, seed=5) * 0.5)
    base = over(base, radial_blur(far, vx, vy, 0.16))
    sharp = render_rgba(keep=near)
    chars = render_rgba(keep=objects_of(runner) + objects_of(hunter) + objects_of(hunter2))
    base = over(base, sharp)
    base = over(base, outline(chars, 4.0 * s, rim=2.0 * s, drop=1.5 * s))
    base = paint(base, WHITE, streaks(vx, vy, 150, 0.5, seed=9) * 0.85)
    base = paint(base, YELLOW, streaks(vx, vy, 30, 0.55, seed=21) * 0.8)

    rev, tag = text_masks([[("REVERSE", FONT_BLACK_ITALIC, 1.0)], [("TAG!", FONT_BLACK_ITALIC, 1.45)]],
                          int(360 * s), int(170 * s), rot=12.0, row_gap=0.0)
    letters = np.maximum(rev, tag)
    face = np.zeros(letters.shape + (4,), dtype=np.float32)
    face = blend_over(face, solid(rev, "#ef4444"))
    face = blend_over(face, solid(tag, YELLOW))
    stick = outline(np.dstack([face[..., :3], letters]), 5.0 * s, rim=2.5 * s, drop=3.0 * s)
    title = smear(stick, int(-70 * s), int(-14 * s), 7, ["#fb923c", "#f472b6", "#a78bfa"])
    base = place(base, title, 205, 92)
    finish(base, path)


CONCEPTS = {
    "a": ("cover_v2a_close_call.png", concept_a),
    "b": ("cover_v2b_reverse.png", concept_b),
    "c": ("cover_v2c_playground.png", concept_c),
    "d": ("cover_v2d_team_up.png", concept_d),
    "e": ("cover_v2e_pixel.png", concept_e),
    "f": ("cover_v2f_arcade.png", concept_f),
    "g": ("cover_v2g_minimal.png", concept_g),
    "h": ("cover_v2h_poster.png", concept_h),
    "i": ("cover_v2i_speed.png", concept_i),
}


def make_sheet(out_dir, names, filename="cover_v2_sheet.png", cols=2):
    """比較用の一覧。上に原寸（630x500）を cols 列で、下に itch.io の最小（315x250）を1列に並べる。
    小さく縮めてもタイトルとキャラが分かるかを見るため（ui_art_sheet.png と同じ考え方）。"""
    gap = 12
    imgs = [ui._load_pixels(os.path.join(out_dir, CONCEPTS[n][0]))[..., :3] for n in names]
    smalls = [im.reshape(H // 2, 2, W // 2, 2, 3).mean(axis=(1, 3)) for im in imgs]
    rows = (len(imgs) + cols - 1) // cols
    sw = max(cols * W + (cols + 1) * gap, len(imgs) * (W // 2) + 2 * gap)
    sh = rows * H + H // 2 + (rows + 2) * gap
    sheet = np.broadcast_to(rgb("#f1f5f9"), (sh, sw, 3)).copy()
    # 配列は下の行から上へ並ぶので、上段の行ほど y が大きい
    for i, im in enumerate(imgs):
        col, row = i % cols, i // cols
        x = gap + col * (W + gap)
        y = sh - gap - (row + 1) * H - row * gap
        sheet[y:y + H, x:x + W] = im
    for i, im in enumerate(smalls):
        x = gap + i * (W // 2)
        sheet[gap:gap + H // 2, x:x + W // 2] = im
    path = os.path.join(out_dir, filename)
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
        make_sheet(out_dir, ["a", "b", "c", "d"])
        make_sheet(out_dir, ["e", "f", "g", "h", "i"], "cover_v2_sheet_2.png", cols=3)


if __name__ == "__main__":
    main()
