"""リスポーン後の目回りを3秒で試作。通常実行は試作のみ。--integrate で既存ゲーム資産へ統合する。

blender -b -P tools/blender/prototype_respawn.py
出力: tools/blender/preview/respawn/
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
OUT = HERE / 'preview' / 'respawn'
sys.path.insert(0, str(HERE))
from prototype_slide import load_helpers, sitting, set_action


def dizzy_pose(frame):
    pose = sitting()
    a = frame / 27.0 * math.tau
    # 腰と足は固定。前後の傾きと左右の傾きを位相差90度で合成する。
    pose['Spine'] = (7 + 12 * math.cos(a), 0, 13 * math.sin(a))
    pose['Chest'] = (5 + 8 * math.cos(a - 0.35), 0, 8 * math.sin(a - 0.35))
    pose['UpperArm.L'] = (12, 0, -22)
    pose['UpperArm.R'] = (12, 0, 22)
    pose['Shin.L'] = (22, 0, 0)
    pose['Shin.R'] = (22, 0, 0)
    return pose


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    return mat


def orb(name, pos, scale, mat, parent=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, location=pos)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    for face in obj.data.polygons:
        face.use_smooth = True
    return obj


def add_respawn_action(rig, h):
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    keys = {f: dizzy_pose(f) for f in range(0, 82, 3)}
    keys[86] = {
        'Root': {'loc': (0, -0.16, 0)}, 'Spine': (12, 0, 0), 'Chest': (-5, 0, 0),
        'Thigh.L': (-60, 0, 0), 'Thigh.R': (-60, 0, 0),
        'Shin.L': (85, 0, 0), 'Shin.R': (85, 0, 0),
        'UpperArm.L': (20, 0, -22), 'UpperArm.R': (20, 0, 22),
    }
    keys[90] = h['IDLE'][0]
    action, slot = h['make_action'](rig, 'RespawnDizzy', keys, False)
    set_action(rig, action, slot)
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    scene = bpy.context.scene
    for frame in range(91):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        deps = bpy.context.evaluated_depsgraph_get()
        low = min((o.matrix_world @ v.co).z for o in meshes
                  for v in o.evaluated_get(deps).data.vertices)
        root = rig.pose.bones['Root']
        root.location.y += 0.015 - low
        root.keyframe_insert('location', frame=frame)
    return action, slot


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    h = load_helpers()
    bpy.ops.wm.open_mainfile(filepath=str(HERE / 'fallguy.blend'))
    rig = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
    originals = [(s.action, s.action_slot) for t in rig.animation_data.nla_tracks
                 for s in t.strips if s.action.name != 'RespawnDizzy']
    for track in list(rig.animation_data.nla_tracks):
        if track.name == 'RespawnDizzy':
            rig.animation_data.nla_tracks.remove(track)
    old = bpy.data.actions.get('RespawnDizzy')
    if old:
        bpy.data.actions.remove(old)
    action, slot = add_respawn_action(rig, h)
    if '--integrate' in sys.argv:
        h['push_nla'](rig, originals + [(action, slot)])
        h['apply_pose'](rig, {})
        bpy.context.scene.frame_set(0)
        h['export']()
        print('RESPAWN_INTEGRATION_OK')
        return
    scene = bpy.context.scene
    h['push_nla'](rig, [(action, slot)])
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'respawn_dizzy.blend'))
    bpy.ops.export_scene.gltf(filepath=str(OUT / 'respawn_dizzy.glb'),
        export_format='GLB', export_animations=True, export_animation_mode='NLA_TRACKS',
        export_cameras=False, export_lights=False)
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    set_action(rig, action, slot)
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.display.shading.background_type = 'WORLD'
    if scene.world is None:
        scene.world = bpy.data.worlds.new('RespawnPreviewWorld')
    scene.world.color = (0.07, 0.085, 0.115)
    scene.display.render_aa = '8'
    scene.render.resolution_x, scene.render.resolution_y = 640, 520
    scene.render.resolution_percentage = 100
    floor_mat = material('PreviewFloor', (0.24, 0.34, 0.42))
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=1.45, depth=0.10, location=(0, 0, -0.05))
    bpy.context.object.data.materials.append(floor_mat)
    yellow = material('BirdYellow', (1, 0.77, 0.12))
    orange = material('BirdBeak', (1, 0.34, 0.04))
    black = material('BirdEyes', (0.05, 0.035, 0.02))
    birds = []
    for i in range(3):
        bird = bpy.data.objects.new(f'PreviewBird{i}', None)
        scene.collection.objects.link(bird)
        orb('BirdBody', (0, 0, 0), (0.095, 0.13, 0.085), yellow, bird)
        orb('BirdHead', (0, -0.085, 0.065), (0.079, 0.079, 0.079), yellow, bird)
        orb('BirdBeak', (0, -0.163, 0.050), (0.038, 0.048, 0.024), orange, bird)
        for side in (-1, 1):
            orb('BirdEye', (side * 0.045, -0.143, 0.088), (0.012, 0.014, 0.013), black, bird)
            orb('BirdWing', (side * 0.13, 0.018, 0.025), (0.10, 0.060, 0.025), yellow, bird)
        birds.append(bird)
    cam = bpy.data.objects.new('RespawnCamera', bpy.data.cameras.new('RespawnCamera'))
    scene.collection.objects.link(cam)
    cam.location = (2.6, -4.7, 2.4)
    cam.rotation_euler = (Vector((0, 0, 0.83)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.type = 'ORTHO'
    cam.data.ortho_scale = 3.3
    scene.camera = cam
    for frame in range(91):
        scene.frame_set(frame)
        for i, bird in enumerate(birds):
            a = frame / 36 * math.tau + i * math.tau / 3
            rise = max(0.0, (frame - 81) / 9.0)
            bird.location = (0.72 * math.cos(a), 0.72 * math.sin(a),
                             1.48 + rise * 0.5 + 0.04 * math.sin(a * 2))
            bird.rotation_euler.z = a
            scale = max(0, min(1, (90 - frame) / 9))
            bird.scale = (scale, scale, scale)
            bird.keyframe_insert('location', frame=frame)
            bird.keyframe_insert('rotation_euler', frame=frame)
            bird.keyframe_insert('scale', frame=frame)
        scene.render.filepath = str(OUT / f'{frame:03d}.png')
        bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'respawn_preview_scene.blend'))
    print('RESPAWN_PREVIEW_OK', OUT)


if __name__ == '__main__':
    main()
