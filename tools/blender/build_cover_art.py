"""ストアのカバー画像(KAN-54)を、ゲームと同じキャラのモデルから Blender で描いて PNG に書き出す。

    blender -b -P tools/blender/build_cover_art.py -- <出力先.png> [--scale 2]

キャラは tools/blender/fallguy.blend から読み込む(ゲーム内と同じ形・同じポーズになる)。
構図と配色は docs/concept/store/cover_image/SPEC.md・PROMPT.md に合わせ、文字は入れない。
出力は 630x500 の --scale 倍(既定 2 倍。縮めて使うと輪郭がきれいになる)。
"""

import math
import os
import sys

import bpy
from mathutils import Euler, Vector

PROJECT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BEAN_BLEND = os.path.join(PROJECT, "tools", "blender", "fallguy.blend")

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


def srgb(hex_color):
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    h = hex_color.lstrip("#")
    return tuple(lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    scene.eevee.taa_render_samples = 64
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    # 既定の AgX は彩度を大きく落とすので、配色を決めた色がそのまま出る Standard にする
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs[0].default_value = (1.0, 1.0, 1.0, 1.0)
    bg.inputs[1].default_value = 0.42
    # 空の色をそのまま環境光にすると全体が青く白飛びして配色(SPEC)から外れるので、
    # カメラに映る空と、物を照らす弱い白い環境光を分ける
    sky = world.node_tree.nodes.new("ShaderNodeBackground")
    sky.inputs[0].default_value = (*srgb("#93c5fd"), 1.0)
    sky.inputs[1].default_value = 1.0
    mix = world.node_tree.nodes.new("ShaderNodeMixShader")
    path = world.node_tree.nodes.new("ShaderNodeLightPath")
    output = next(n for n in world.node_tree.nodes if n.type == "OUTPUT_WORLD")
    links = world.node_tree.links
    links.new(path.outputs["Is Camera Ray"], mix.inputs[0])
    links.new(bg.outputs[0], mix.inputs[1])
    links.new(sky.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs[0])
    scene.world = world

    for name, energy, rot, shadow in (
            ("Key", 2.25, (52, 0, -38), True),
            ("Fill", 0.4, (70, 0, 55), False)):
        light = bpy.data.lights.new(name, "SUN")
        light.energy = energy
        light.use_shadow = shadow
        light.angle = math.radians(6)
        obj = bpy.data.objects.new(name, light)
        obj.rotation_euler = Euler([math.radians(a) for a in rot], "XYZ")
        scene.collection.objects.link(obj)


_MATS = {}


def mat(hex_color, rough=0.4):
    key = (hex_color, rough)
    if key not in _MATS:
        m = bpy.data.materials.new(hex_color)
        m.use_nodes = True
        bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        rgb = srgb(hex_color)
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        # 影の側が沈まないように、弱く自己発光させる(ゲーム側の見た目に合わせた)
        bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 0.1
        _MATS[key] = m
    return _MATS[key]


def _finish(obj, material, loc, rot, bevel=0.0):
    obj.data.materials.append(material)
    obj.location = loc
    obj.rotation_euler = Euler([math.radians(a) for a in rot], "XYZ")
    if bevel > 0:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 5
    return obj


def box(size, material, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.08):
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    obj = bpy.context.object
    obj.scale = size
    bpy.ops.object.transform_apply(scale=True)
    return _finish(obj, material, loc, rot, bevel)


def cyl(r1, depth, material, loc=(0, 0, 0), r2=None, rot=(0, 0, 0), bevel=0.0):
    bpy.ops.mesh.primitive_cone_add(vertices=64, radius1=r1, radius2=r1 if r2 is None else r2, depth=depth)
    obj = bpy.context.object
    bpy.ops.object.shade_smooth()
    return _finish(obj, material, loc, rot, bevel)


def ball(size, material, loc):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=1.0)
    obj = bpy.context.object
    obj.scale = size
    bpy.ops.object.shade_smooth()
    return _finish(obj, material, loc, (0, 0, 0))


def tower(x, y, r, h, color):
    cyl(r, h, mat(color), loc=(x, y, h / 2))
    cyl(r * 1.3, h * 0.8, mat(color), loc=(x, y, h + h * 0.4), r2=0.0)


def bean(body_hex, clip, frame, loc=(0, 0, 0), yaw=0.0, tilt=(0.0, 0.0), scale=1.0):
    """ゲームのキャラを指定のアニメの1コマで立たせる。yaw は 0 で正面、正で画面の右を向く。"""
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
                bsdf = next(n for n in slot.material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
                bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
                bsdf.inputs["Roughness"].default_value = 0.32
                bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
                bsdf.inputs["Emission Strength"].default_value = 0.1
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


def horns(rig):
    """鬼の角。ロゴのキャラ(build_ui_art.py)と同じ付け方。"""
    for sx in (-1, 1):
        horn = cyl(0.13, 0.42, mat(YELLOW), loc=(sx * 0.2, 0.0, 1.66), r2=0.0, rot=(0, sx * 14, 0))
        horn.parent = rig


def dash_panel(cx, cy, length, width, rot_z):
    """地面の縞のダッシュパネル。"""
    base = box((width, length, 0.06), mat(ORANGE), loc=(cx, cy, 0.03), rot=(0, 0, rot_z), bevel=0.02)
    n = 5
    for i in range(n):
        v = (i + 0.5) / n - 0.5
        a = math.radians(rot_z)
        ox, oy = -math.sin(a) * v * length, math.cos(a) * v * length
        box((width * 0.82, length / n * 0.45, 0.04), mat(YELLOW), loc=(cx + ox, cy + oy, 0.075),
            rot=(0, 0, rot_z), bevel=0.01)
    return base


def present(x, y, s=0.55):
    """ゲームの？ブロックの代わりに置く、赤いプレゼント箱(マップ上のアイテムと同じ見た目)。"""
    box((s, s, s), mat(HUNTER), loc=(x, y, s / 2 + 0.02), bevel=0.04)
    box((s * 1.03, s * 0.22, s * 1.03), mat(WHITE), loc=(x, y, s / 2 + 0.02), bevel=0.02)
    box((s * 0.22, s * 1.03, s * 1.03), mat(WHITE), loc=(x, y, s / 2 + 0.02), bevel=0.02)


def build():
    # 地面と、奥へ段々に上がるゾーンの色
    box((90, 60, 1), mat(LIME, 0.6), loc=(0, 12, -0.5), bevel=0.0)
    box((26, 12, 1.4), mat(SKY_BLUE, 0.6), loc=(-13, 24, 0.7), bevel=0.15)
    box((20, 12, 2.2), mat(PURPLE, 0.6), loc=(10, 28, 1.1), bevel=0.15)
    box((26, 12, 1.0), mat(PINK, 0.6), loc=(16, 17, 0.5), bevel=0.15)

    # 塔(ゲームのマップにある円柱+円錐の建物)
    tower(-15, 22, 1.5, 3.2, RUNNER)
    tower(-9, 26, 1.1, 2.4, SKY_BLUE)
    tower(13, 24, 1.3, 2.8, HOT_PINK)
    tower(19, 19, 1.7, 3.6, PURPLE)

    # 滑り台(奥の青い段から下りてくる、ピンクと水色の帯)
    box((3.4, 13, 0.22), mat(HOT_PINK), loc=(-5.2, 14.0, 1.25), rot=(11, 0, 0), bevel=0.06)
    box((1.0, 13, 0.25), mat("#bae6fd"), loc=(-5.2, 14.0, 1.32), rot=(11, 0, 0), bevel=0.05)

    # 手前の主役: 黄色い壁の陰に隠れて鬼をのぞく緑の逃走者
    box((0.8, 3.0, 2.5), mat(YELLOW), loc=(-0.55, -2.2, 1.25), rot=(0, 0, -16), bevel=0.2)
    bean(RUNNER, "Idle", 0, loc=(-1.75, -3.9, 0), yaw=42, tilt=(0.0, 12.0), scale=1.3)

    # 奥: 逃走者と反対(右)を向いて探している赤い鬼が2人
    horns(bean(HUNTER, "Idle", 0, loc=(3.3, 1.0, 0), yaw=52, scale=1.35))
    horns(bean(HUNTER, "Run", 6, loc=(5.9, 3.0, 0), yaw=70, scale=1.35))

    dash_panel(3.0, -2.6, 2.8, 1.5, -30)
    present(-4.6, 1.2)
    present(1.1, 6.8)

    # 雲(上の空はロゴ用に広く空けるので、端に寄せる)
    for x, y, z, sx in ((-17, 38, 15.5, 4.6), (-13.5, 38, 16.2, 3.0), (19, 38, 14.5, 4.2)):
        ball((sx, sx * 0.55, sx * 0.3), mat(WHITE, 0.8), (x, y, z))


def camera():
    scene = bpy.context.scene
    data = bpy.data.cameras.new("Cam")
    data.lens = 40
    cam = bpy.data.objects.new("Cam", data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.8, -13.5, 2.7)
    target = Vector((0.8, 4.0, 3.3))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()


def main():
    args = sys.argv[sys.argv.index("--") + 1:]
    out = os.path.abspath(args[0])
    scale = int(args[args.index("--scale") + 1]) if "--scale" in args else 2
    reset()
    build()
    camera()
    scene = bpy.context.scene
    scene.render.resolution_x = 630 * scale
    scene.render.resolution_y = 500 * scale
    scene.render.resolution_percentage = 100
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("render :", out)


main()
