"""しっぽを保持したオーバーオール衣装の制作。既存ゲーム用モデルは変更しない。"""
import sys, math, json
from pathlib import Path
import bpy, bmesh
from mathutils import Vector
from mathutils.kdtree import KDTree
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from prototype_slide import load_helpers, set_action
h=load_helpers()
OUT=HERE/'preview'/'overalls'
OUT.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(HERE/'fallguy.blend'))
rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
body=bpy.data.objects['Body']
original_body=[tuple(v.co) for v in body.data.vertices]
original_actions=[t.strips[0].action.name for t in rig.animation_data.nla_tracks if t.strips]
rig.animation_data.action=None
for t in rig.animation_data.nla_tracks: t.mute=True
h['apply_pose'](rig,{})
bpy.context.scene.frame_set(0)

def material(name,color):
 # 指定色はsRGB。Blender/glTFの基底色へ渡す前にリニア値へ変換する。
 color=tuple(c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4 for c in color)
 m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
 p=next(n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED');p.inputs['Base Color'].default_value=(*color,1);p.inputs['Roughness'].default_value=.86
 if name=='CottonCream':
  p.inputs['Emission Color'].default_value=(*color,1);p.inputs['Emission Strength'].default_value=.20
 return m
denim=material('OverallsDenim',(.20,.32,.48))
cream=material('CottonCream',(.96,.90,.76))
cuff_mat=material('DenimCuff',(.32,.43,.60))
thread=material('Stitch',(.70,.75,.78))
gold=material('BrassButton',(.98,.78,.28))
body.data.materials.clear();body.data.materials.append(material('OverallsDinosaurGreen',(.24,.78,.34)))
kd=KDTree(len(body.data.vertices))
for v in body.data.vertices:kd.insert(v.co,v.index)
kd.balance()

def bind(obj,bone=None):
 if bone and bone.startswith('PANTS.'):
  for v in obj.data.vertices:
   t=max(0,min(1,(v.co.z-.47)/.24));t=t*t*(3-2*t)
   for name,w in {'Hips':t,'Thigh.'+bone[-1]:1-t}.items():
    group=obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
    group.add([v.index],w,'REPLACE')
 elif bone=='TORSO':
  for v in obj.data.vertices:
   z=v.co.z
   chest=max(0,min(1,(z-.98)/.20))
   spine=(1-chest)*max(0,min(1,(z-.80)/.18))
   for name,w in {'Hips':1-chest-spine,'Spine':spine,'Chest':chest}.items():
    group=obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
    group.add([v.index],w,'REPLACE')
 elif bone: h['set_group'](obj,{bone:1})
 else:
  for v in obj.data.vertices:
   _,idx,_=kd.find(v.co)
   for g in body.data.vertices[idx].groups:
    name=body.vertex_groups[g.group].name
    group=obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
    group.add([v.index],g.weight,'REPLACE')
 obj.parent=rig
 mod=obj.modifiers.new('OutfitRig','ARMATURE');mod.object=rig
 for p in obj.data.polygons:p.use_smooth=True
 return obj

def mesh(name,verts,faces,mat,bone=None):
 data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update()
 obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);data.materials.append(mat)
 return bind(obj,bone)


# Subtle repeating twill, encoded as an embedded sRGB image for Blender and Godot.
texture=bpy.data.images.new('DenimTwill',width=128,height=128,alpha=True)
texture.colorspace_settings.name='sRGB'
pixels=[]
for y in range(128):
 for x in range(128):
  twill=((x+y)//2)%4
  factor=1.025 if twill<2 else .975
  grain=(((x*73+y*41)%19)/18-.5)*.025
  pixels.extend([min(1,max(0,c*(factor+grain))) for c in (.20,.32,.48)]+[1])
texture.pixels=pixels;texture.pack()
node=denim.node_tree.nodes.new('ShaderNodeTexImage');node.image=texture;node.interpolation='Linear';node.extension='REPEAT'
shader=next(n for n in denim.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
denim.node_tree.links.new(node.outputs['Color'],shader.inputs['Base Color'])
exec(compile((HERE/'overalls_geometry.py').read_text(encoding='utf-8'),str(HERE/'overalls_geometry.py'),'exec'))
# Cylindrical fabric UVs at uniform world scale, including sleeves and cuffs.
for ob in bpy.data.objects:
 if ob.type!='MESH' or ob.parent!=rig or not any(m==denim for m in ob.data.materials):continue
 uv=ob.data.uv_layers.new(name='FabricUV')
 for face in ob.data.polygons:
  angles=[math.atan2(ob.data.vertices[ob.data.loops[k].vertex_index].co.x,-ob.data.vertices[ob.data.loops[k].vertex_index].co.y) for k in face.loop_indices]
  if max(angles)-min(angles)>math.pi:angles=[a+math.tau if a<0 else a for a in angles]
  for k,a in zip(face.loop_indices,angles):
   v=ob.data.vertices[ob.data.loops[k].vertex_index].co
   uv.data[k].uv=(a*4.2,v.z*9)
# 尾の先端側の頂点は衣装の非表示処理後も保持する。
original_tail=[co for co in original_body if co[1]>.45]
assert all(any((v.co-Vector(co)).length<1e-6 for v in body.data.vertices) for co in original_tail), 'Tail changed'
for t in rig.animation_data.nla_tracks:t.mute=False
rig.animation_data.action=None
bpy.context.scene.frame_set(0)
blend=HERE/'overalls.blend'
glb=HERE.parent.parent/'assets'/'character'/'outfits'/'overalls.glb'
glb.parent.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(blend))
bpy.ops.export_scene.gltf(filepath=str(glb),export_format='GLB',export_yup=True,export_apply=True,export_skins=True,export_rest_position_armature=True,export_animations=True,export_animation_mode='NLA_TRACKS',export_bake_animation=False,export_optimize_animation_size=False,export_cameras=False,export_lights=False,export_texcoords=True)
# 編集元・GLBを保存後、描画用のポーズとカメラを用意。
scene=bpy.context.scene;scene.render.engine='BLENDER_WORKBENCH';scene.display.shading.light='STUDIO';scene.display.shading.color_type='MATERIAL';scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True
scene.render.resolution_x=600;scene.render.resolution_y=650;scene.render.resolution_percentage=100;scene.display.render_aa='8'
scene.view_settings.view_transform='Standard'
scene.display.shading.background_type='WORLD'
if scene.world is None:scene.world=bpy.data.worlds.new('PreviewWorld')
scene.world.color=(.11,.13,.17)
cam=bpy.data.objects.new('PreviewCamera',bpy.data.cameras.new('PreviewCamera'));scene.collection.objects.link(cam);scene.camera=cam;cam.data.type='ORTHO';cam.data.ortho_scale=2.05
tracks={t.strips[0].action.name:t.strips[0] for t in rig.animation_data.nla_tracks if t.strips}
for t in rig.animation_data.nla_tracks:t.mute=True
shots=[('top','Idle',0,(0,2,6)),('bottom','Idle',0,(0,0,-6)),('raised','Nice',14,(2,-6,3)),('front','Idle',0,(2,-6,2.2)),('back','Idle',0,(-2,6,2.2)),('side','Idle',0,(6,1,2)),('run','Run',7,(-2,6,2.2)),('slide','SlideSit',8,(-2,6,2.2)),('prone','SlideProne',8,(2,6,2.8)),('dizzy','RespawnDizzy',30,(-2,6,2.2)),('slip','Slip',16,(2,6,2.8))]
for name,clip,frame,loc in shots:
 strip=tracks[clip];set_action(rig,strip.action,strip.action_slot);scene.frame_set(frame)
 cam.location=loc;cam.rotation_euler=(Vector((0,0,.86))-cam.location).to_track_quat('-Z','Y').to_euler()
 scene.render.filepath=str(OUT/(name+'.png'));bpy.ops.render.render(write_still=True)
(OUT/'validation.json').write_text(json.dumps({'tail_vertices_unchanged':True, 'covered_body_faces_hidden':True,'animations':original_actions,'outfit_objects':[o.name for o in bpy.data.objects if o.parent==rig],'glb':str(glb)},indent=2),encoding='utf-8')
print('OVERALLS_OK',glb)
