"""滑り台モーションの試作/組み込み。通常実行は独立した試作を出力する。

blender -b -P tools/blender/prototype_slide.py -- [--render]
blender -b -P tools/blender/prototype_slide.py -- --integrate
--integrate は承認済みモーションを既存キャラクター資産へ追加する。
出力: tools/blender/preview/slide/ (Godot インポート対象外)
"""
import ast
import math
import os
import sys
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
OUT = HERE / 'preview' / 'slide'


def load_helpers():
    path = HERE / 'build_fallguy.py'
    tree = ast.parse(path.read_text(encoding='utf-8'))
    # 既存ビルダーの末尾 main() は実行せず、ポーズ作成関数だけ再利用する。
    tree.body = [n for n in tree.body if not (
        isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
        and isinstance(n.value.func, ast.Name) and n.value.func.id == 'main')]
    ns = {'__file__': str(path), '__name__': 'slide_helpers'}
    exec(compile(tree, str(path), 'exec'), ns)
    return ns


def sitting(roll=0):
    return {
        'Root': {'loc': (0, -0.43, 0)},
        'Spine': (8, 0, roll), 'Chest': (5, 0, -roll / 2),
        'Thigh.L': (-88, 0, -5), 'Thigh.R': (-88, 0, 5),
        'Shin.L': (12, 0, 0), 'Shin.R': (12, 0, 0),
        'Foot.L': (-8, 0, 0), 'Foot.R': (-8, 0, 0),
        'UpperArm.L': (-8, 0, -38 - roll), 'UpperArm.R': (-8, 0, 38 - roll),
    }


def prone(rock=0):
    return {
        'Root': {'loc': (0, -0.35, 0)}, 'Hips': (86, 0, 0),
        'Spine': (-3, 0, rock), 'Chest': (-9, 0, -rock),
        # 顔の左右へ手を逃がす。転倒終盤/うつ伏せ/回復開始で共用する。
        'UpperArm.L': (-90, 0, -48), 'UpperArm.R': (-90, 0, 48),
        'Hand.L': (15, 0, 0), 'Hand.R': (15, 0, 0),
        'Thigh.L': (3, 0, -5), 'Thigh.R': (3, 0, 5),
        'Shin.L': (12 + rock, 0, 0), 'Shin.R': (12 - rock, 0, 0),
        'Foot.L': (-12, 0, 0), 'Foot.R': (-12, 0, 0),
    }


def make_clips(h):
    crouch = {
        'Root': {'loc': (0, -0.20, 0)}, 'Hips': (35, 0, 0),
        'Spine': (15, 0, 0), 'Chest': (-12, 0, 0),
        'Thigh.L': (-65, 0, 0), 'Thigh.R': (-65, 0, 0),
        'Shin.L': (100, 0, 0), 'Shin.R': (100, 0, 0),
        'UpperArm.L': (-50, 0, -24), 'UpperArm.R': (-50, 0, 24),
    }
    falling = prone()
    falling['Hips'] = (48, 0, 0)
    falling['Root'] = {'loc': (0, -0.12, 0)}
    return {
        'SlideEnter': ({0: h['IDLE'][0], 7: sitting()}, False),
        'SlideSit': ({0: sitting(), 10: sitting(3), 20: sitting(-3), 30: sitting()}, True),
        'SlideReverseFall': ({0: h['RUN_CONTACT'], 5: h['RUN_PASS'],
                              10: h['mirror'](h['RUN_CONTACT']),
                              15: h['mirror'](h['RUN_PASS']),
                              20: h['RUN_CONTACT'],
                              25: falling, 31: prone()}, False),
        'SlideProne': ({0: prone(), 10: prone(2), 20: prone(-2), 30: prone()}, True),
        'SlideRecover': ({0: prone(), 3: crouch, 8: h['RUN_CONTACT']}, False),
    }


def set_action(rig, action, slot):
    rig.animation_data.action = action
    rig.animation_data.action_slot = slot


def add_slide_actions(rig, h):
    """試作と本番ビルダーで、承認済みのポーズ/接地補正を共用する。"""
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    made = []
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    for name, (keys, loop) in make_clips(h).items():
        action, slot = h['make_action'](rig, name, keys, loop)
        set_action(rig, action, slot)
        # 各フレームの最下点を床上にそろえ、短い脚でも床へ埋まらないようにする。
        for frame in range(max(keys) + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            deps = bpy.context.evaluated_depsgraph_get()
            low = min((o.matrix_world @ v.co).z for o in meshes
                      for v in o.evaluated_get(deps).data.vertices)
            root = rig.pose.bones['Root']
            root.location.y += 0.015 - low
            root.keyframe_insert('location', frame=frame)
        made.append((action, slot))
    return made


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    h = load_helpers()
    bpy.ops.wm.open_mainfile(filepath=str(HERE / 'fallguy.blend'))
    rig = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
    assert 'Hips' in rig.pose.bones
    # 組み込み時も既存7クリップ/メッシュ/ウェイトをそのまま維持する。
    originals = [(s.action, s.action_slot) for t in rig.animation_data.nla_tracks
                 for s in t.strips if not s.action.name.startswith('Slide')]
    for track in list(rig.animation_data.nla_tracks):
        if track.name.startswith('Slide'):
            rig.animation_data.nla_tracks.remove(track)
    for action in list(bpy.data.actions):
        if action.name.startswith('Slide'):
            bpy.data.actions.remove(action)
    made = add_slide_actions(rig, h)
    if '--integrate' in sys.argv:
        h['push_nla'](rig, originals + made)
        h['apply_pose'](rig, {})
        bpy.context.scene.frame_set(0)
        h['export']()
        print('SLIDE_INTEGRATION_OK')
        return
    h['push_nla'](rig, made)
    h['apply_pose'](rig, {})
    bpy.context.scene.frame_set(0)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'slide_prototype.blend'))
    bpy.ops.export_scene.gltf(filepath=str(OUT / 'slide_prototype.glb'),
        export_format='GLB', export_animations=True, export_animation_mode='NLA_TRACKS',
        export_cameras=False, export_lights=False)
    if '--render' in sys.argv:
        render(rig, made)
    print('SLIDE_PROTOTYPE_OK', str(OUT))


def render(rig, made):
    scene = bpy.context.scene
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.display.shading.background_type = 'WORLD'
    if scene.world is None:
        scene.world = bpy.data.worlds.new('PreviewWorld')
    scene.world.color = (0.065, 0.080, 0.11)
    scene.display.render_aa = '8'
    scene.render.resolution_x = 560
    scene.render.resolution_y = 420
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, -0.10))
    ramp = bpy.context.object
    ramp.name = 'PreviewRamp'
    ramp.scale = (2.1, 7, 0.15)
    pitch = math.atan(0.25)
    ramp.rotation_euler.x = pitch
    ramp.color = (0.20, 0.55, 0.68, 1)
    mat = bpy.data.materials.new('PreviewRampMaterial')
    mat.diffuse_color = (0.20, 0.55, 0.68, 1)
    ramp.data.materials.append(mat)
    cam = bpy.data.objects.new('PreviewCamera', bpy.data.cameras.new('PreviewCamera'))
    scene.collection.objects.link(cam)
    cam.location = (4.2, -5.4, 3.5)
    cam.rotation_euler = (Vector((0, 0, 0.75)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.type = 'ORTHO'
    cam.data.ortho_scale = 4.6
    scene.camera = cam
    lookup = {a.name: (a, s) for a, s in made}
    for mode in ('normal', 'reverse'):
        folder = OUT / mode
        folder.mkdir(exist_ok=True)
        for i in range(60):
            if mode == 'normal':
                name, f = ('SlideEnter', i) if i < 7 else ('SlideSit', (i - 7) % 30)
                y = 1.1 - i * 0.038
                yaw = 0
            else:
                if i <= 15:
                    name, f = 'SlideReverseFall', min(i * 2.0, 31)
                elif i < 46:
                    name, f = 'SlideProne', (i - 16) % 30
                elif i <= 54:
                    name, f = 'SlideRecover', i - 46
                else:
                    name, f = 'SlideRecover', 8
                y = -0.25 + min(i, 10) * (0.75 / 10) - max(i - 10, 0) * 0.035
                yaw = math.pi
            set_action(rig, *lookup[name])
            scene.frame_set(int(f), subframe=f % 1)
            rig.location = (0, y, 0.25 * y)
            # 上りを向いても同じ走路面に沿わせる。
            rig.rotation_euler = (pitch if yaw == 0 else -pitch, 0, yaw)
            scene.render.filepath = str(folder / f'{i:03d}.png')
            bpy.ops.render.render(write_still=True)


if __name__ == '__main__':
    main()
