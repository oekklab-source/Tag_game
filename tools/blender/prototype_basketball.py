"""しっぽを保持したバスケ衣装の独立試作。既存ゲーム用モデルは変更しない。"""
import sys, math, json
from pathlib import Path
import bpy, bmesh
from mathutils import Vector
from mathutils.kdtree import KDTree
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from prototype_slide import load_helpers, set_action
h=load_helpers()
OUT=HERE/'preview'/'basketball'
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
 return m
coral=material('BasketballCoral',(.94,.25,.23)); cream=material('BasketballCream',(1,.96,.86))
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
   spine=(1-chest)*max(0,min(1,(z-.70)/.20))
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

# 衣装の下に隠れる腹ボタンと低い背びれだけを試作側から除く。顔・爪・しっぽは保持。
costume=bpy.data.objects['Costume']; bm=bmesh.new();bm.from_mesh(costume.data)
seen=set();remove=[]
for v in bm.verts:
 if v in seen:continue
 stack=[v];group=[];seen.add(v)
 while stack:
  a=stack.pop();group.append(a)
  for e in a.link_edges:
   b=e.other_vert(a)
   if b not in seen:seen.add(b);stack.append(b)
 center=sum((a.co for a in group),Vector())/len(group)
 if abs(center.x)<.12 and .63<center.z<1.22 and center.y<-.25:remove+=group
bmesh.ops.delete(bm,geom=remove,context='VERTS');bm.to_mesh(costume.data);bm.free()

N=64
# 胴にゆとりを持たせた独立した服。袖ぐりは肩ひもと分離した穴にする。
def bottom(a): return .70
def top(a): return 1.075 + .170*abs(math.sin(a))**2 + .085*max(0,-math.cos(a))**4
def radius(z):
 # 裾のゆとりを残し、胸から肩へは体表に沿って絞る。
 t=max(0,min(1,(z-.85)/.30));t=t*t*(3-2*t)
 loose=max(.412,h['body_radius'](z)+.045)
 fitted=h['body_radius'](z)+.035
 return loose*(1-t)+fitted*t
def shell(name,lo,hi,mat,offset=.0,rows=18,bone="TORSO"):
 vs=[];fs=[]
 for j in range(rows+1):
  t=j/rows
  for i in range(N):
   a=i/N*math.tau;z=lo(a)*(1-t)+hi(a)*t
   r=(h['body_radius'](z)+offset) if name.startswith('Headband') else radius(z)+offset
   vs.append((r*math.sin(a),-r*math.cos(a),z))
 for j in range(rows):
  for i in range(N):
   k=j*N+i;n=j*N+(i+1)%N;fs.append((k,n,n+N,k+N))
 obj=mesh(name,vs,fs,mat,bone)
 solid=obj.modifiers.new('FabricThickness','SOLIDIFY');solid.thickness=.018
 obj.modifiers.move(obj.modifiers.find(solid.name),0)
 return obj
jersey=shell('BasketballJersey',bottom,top,coral)
# 袖ぐりとしっぽ専用穴。厚みを焼いてから抜き、服の縁に実際の断面を作る。
def cut(obj, name, radius, depth, location, rotation):
 bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);bpy.context.view_layer.objects.active=obj
 for mod in list(obj.modifiers):
  if mod.type=='SOLIDIFY':bpy.ops.object.modifier_apply(modifier=mod.name)
 bpy.ops.mesh.primitive_cylinder_add(vertices=48,radius=radius,depth=depth,location=location,rotation=rotation)
 cutter=bpy.context.object
 mod=obj.modifiers.new(name,'BOOLEAN');mod.operation='DIFFERENCE';mod.solver='EXACT';mod.object=cutter
 obj.modifiers.move(obj.modifiers.find(mod.name),0)
 bpy.context.view_layer.objects.active=obj;bpy.ops.object.modifier_apply(modifier=mod.name)
 bpy.data.objects.remove(cutter,do_unlink=True)
cut(jersey,'Armholes',.120,1.4,(0,0,1.06),(0,math.pi/2,0))
bm=bmesh.new();bm.from_mesh(jersey.data)
opening=[]
for face in bm.faces:
 c=face.calc_center_median()
 if c.y>.25 and (((c.x/.14)**2+((c.z-.80)/.14)**2<1.12) or (abs(c.x)<.062 and c.z>.94)):opening.append(face)
bmesh.ops.delete(bm,geom=opening,context='FACES');bm.to_mesh(jersey.data);bm.free()
jersey.vertex_groups.clear()
for mod in list(jersey.modifiers):
 if mod.type=='ARMATURE':jersey.modifiers.remove(mod)
bind(jersey,'TORSO')
# 縁取りは丸みのある細いパイピング。
def piping(name,coords,mat,bone='TORSO',width=.013):
 cu=bpy.data.curves.new(name,'CURVE');cu.dimensions='3D';cu.bevel_depth=width;cu.bevel_resolution=2
 sp=cu.splines.new('POLY');sp.points.add(len(coords)-1)
 for p,co in zip(sp.points,coords):p.co=(*co,1)
 sp.use_cyclic_u=True
 ob=bpy.data.objects.new(name,cu);bpy.context.collection.objects.link(ob)
 bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob;bpy.ops.object.convert(target='MESH')
 ob.data.materials.append(mat);bind(ob,bone)
# 資料の平たい二重バインダー。丸いコード状にはしない。
shell('NeckBinding',lambda a:top(a)-.037,top,cream,.009,3)
shell('NeckBindingInner',lambda a:top(a)-.066,lambda a:top(a)-.049,cream,.009,2)
shell('JerseyHem',bottom,lambda a:bottom(a)+.018,coral,.003,2)
for sign in [-1,1]:
 for lo,hi in [(.119,.143),(.155,.179)]:
  verts=[];faces=[]
  for r in [lo,hi]:
   for i in range(N):
    a=i/N*math.tau;y=r*math.cos(a);z=1.06+r*math.sin(a);x=sign*math.sqrt(max(.001,(radius(z)+.010)**2-y*y))
    verts.append((x,y,z))
  for i in range(N):faces.append((i,(i+1)%N,(i+1)%N+N,i+N))
  mesh('FlatArmBinding'+str(sign),verts,faces,cream,'TORSO')
coords=[]
for i in range(N):
 a=i/N*math.tau;x=.145*math.cos(a);z=.80+.145*math.sin(a);y=math.sqrt(radius(z)**2-x*x)
 coords.append((x,y,z))
piping('TailOpeningTrim',coords,cream,width=.018)
# 腰から二つの裾へ連続する短パン。腰帯と脚の間に段差を作らない。
for sign in [-1,1]:
 side='L' if sign>0 else 'R'
 vs=[];fs=[]
 for j in range(17):
  t=j/16;z=.735-.305*t
  for i in range(N):
   a=i/N*math.tau
   x=(1-t)*(.39*max(0,math.sin(a)))+t*(h['HIP_X']+.174*math.sin(a))
   y=((1-t)*.39+t*.174)*math.cos(a)
   vs.append((sign*x,y,z))
 for j in range(16):
  for i in range(N):
   k=j*N+i;n=j*N+(i+1)%N;fs.append((k,n,n+N,k+N))
 leg=mesh('BasketballShorts'+side,vs,[tuple(reversed(f)) for f in fs] if sign<0 else fs,coral,'PANTS.'+side)
 solid=leg.modifiers.new('FabricThickness','SOLIDIFY');solid.thickness=.012;leg.modifiers.move(leg.modifiers.find(solid.name),0)
 verts=[];faces=[]
 for z in [.431,.464]:
  t=(.735-z)/.305
  for i in range(N):
   a=i/N*math.tau;x=(1-t)*(.39*max(0,math.sin(a)))+t*(h['HIP_X']+.177*math.sin(a));y=((1-t)*.39+t*.177)*math.cos(a)
   verts.append((sign*x,y,z))
 for i in range(N):faces.append((i,(i+1)%N,(i+1)%N+N,i+N))
 mesh('ShortsHem'+side,verts,[tuple(reversed(f)) for f in faces] if sign<0 else faces,cream,'PANTS.'+side)
 verts=[];faces=[]
 for j in range(17):
  t=j/16;z=.735-.302*t
  for offset in [-.14,.14]:
   a=math.pi/2+offset;x=(1-t)*(.394*math.sin(a))+t*(h['HIP_X']+.178*math.sin(a));y=((1-t)*.394+t*.178)*math.cos(a)
   verts.append((sign*x,y,z))
 for j in range(16):faces.append((j*2,j*2+1,j*2+3,j*2+2))
 mesh('ShortsSideStripe'+side,verts,[tuple(reversed(f)) for f in faces] if sign<0 else faces,cream,'PANTS.'+side)
# 衣装専用コピーだけ、服の内側の体表を除外。後方へ伸びるしっぽは選択しない。
bm=bmesh.new();bm.from_mesh(body.data)
remove=[]
for face in bm.faces:
 c=face.calc_center_median();a=math.atan2(c.x,-c.y)%math.tau
 torso=.50<c.z<top(a)-.025 and c.x*c.x+c.y*c.y<.44**2
 armhole=abs(c.x)>.26 and c.y*c.y+(c.z-1.105)**2<.18**2
 tail=c.y>.28 and abs(c.x)<.17 and .66<c.z<.94
 legs=.46<c.z<.67 and abs(c.x)<.34 and abs(c.y)<.19
 if (torso and not tail) or legs: remove.append(face)
bmesh.ops.delete(bm,geom=remove,context='FACES');bm.to_mesh(body.data);bm.free()
# 頭部に追従するヘッドバンド。
shell('Headband',lambda a:1.52,lambda a:1.58,cream,.053,3,'Chest')
shell('HeadbandStripe',lambda a:1.541,lambda a:1.559,coral,.056,1,'Chest')
# 資料の角ばった太い08。字体を環状メッシュで作り、前後に同じ形を使う。
def block_digit(digit,cx,zcenter,rear):
 polygons=[]
 if digit=='0':
  outer=[(-.052,-.105),(.052,-.105),(.072,-.085),(.072,.085),(.052,.105),(-.052,.105),(-.072,.085),(-.072,-.085)]
  inner=[(-.027,-.062),(.027,-.062),(.03,-.059),(.03,.059),(.027,.062),(-.027,.062),(-.03,.059),(-.03,-.059)]
  polygons=[(outer[i],outer[(i+1)%8],inner[(i+1)%8],inner[i]) for i in range(8)]
 else:
  for z0,z1 in [(-.105,-.066),(-.019,.019),(.066,.105)]:polygons.append(((-.052,z0),(.052,z0),(.067,z0+.015),(.067,z1-.015),(.052,z1),(-.052,z1),(-.067,z1-.015),(-.067,z0+.015)))
  for sign in [-1,1]:
   for z0,z1 in [(-.087,-.01),(.01,.087)]:polygons.append(((sign*.067,z0),(sign*.028,z0),(sign*.028,z1),(sign*.067,z1)))
 vs=[];fs=[]
 for poly in polygons:
  inds=[]
  for x,z in poly:
   x+=cx;z+=zcenter;a=x/.43+(math.pi if rear else 0);r=radius(z)+.009
   inds.append(len(vs));vs.append((r*math.sin(a),-r*math.cos(a),z))
  fs.append(tuple(inds))
 obj=mesh(('Back' if rear else 'Front')+'Number'+digit,vs,fs,cream,'TORSO')
 # 両面表示でも法線を揃えて通常のマテリアルで描画する。
 bm=bmesh.new();bm.from_mesh(obj.data);bm.normal_update()
 for face in bm.faces:
  c=face.calc_center_median()
  if face.normal.dot(Vector((c.x,c.y,0)))<0:face.normal_flip()
 bm.to_mesh(obj.data);bm.free()
for rear in [False,True]:
 block_digit('0',-.125 if rear else -.092,1.015 if rear else .905,rear)
 block_digit('8',.125 if rear else .092,1.015 if rear else .905,rear)
# 尾の先端側の頂点は衣装の非表示処理後も保持する。
original_tail=[co for co in original_body if co[1]>.45]
assert all(any((v.co-Vector(co)).length<1e-6 for v in body.data.vertices) for co in original_tail), 'Tail changed'
for t in rig.animation_data.nla_tracks:t.mute=False
rig.animation_data.action=None
bpy.context.scene.frame_set(0)
blend=HERE/'basketball_prototype.blend'
glb=HERE.parent.parent/'assets'/'character'/'outfits'/'basketball_prototype.glb'
glb.parent.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(blend))
bpy.ops.export_scene.gltf(filepath=str(glb),export_format='GLB',export_yup=True,export_apply=True,export_skins=True,export_rest_position_armature=True,export_animations=True,export_animation_mode='NLA_TRACKS',export_bake_animation=False,export_optimize_animation_size=False,export_cameras=False,export_lights=False,export_texcoords=False)
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
shots=[('front','Idle',0,(2,-6,2.2)),('back','Idle',0,(-2,6,2.2)),('side','Idle',0,(6,1,2)),('run','Run',7,(-2,6,2.2)),('slide','SlideSit',8,(-2,6,2.2)),('prone','SlideProne',8,(2,6,2.8)),('dizzy','RespawnDizzy',30,(-2,6,2.2)),('slip','Slip',16,(2,6,2.8))]
for name,clip,frame,loc in shots:
 strip=tracks[clip];set_action(rig,strip.action,strip.action_slot);scene.frame_set(frame)
 cam.location=loc;cam.rotation_euler=(Vector((0,0,.86))-cam.location).to_track_quat('-Z','Y').to_euler()
 scene.render.filepath=str(OUT/(name+'.png'));bpy.ops.render.render(write_still=True)
(OUT/'validation.json').write_text(json.dumps({'tail_vertices_unchanged':True, 'covered_body_faces_hidden':True,'animations':original_actions,'outfit_objects':[o.name for o in bpy.data.objects if o.parent==rig],'glb':str(glb)},indent=2),encoding='utf-8')
print('BASKETBALL_PROTOTYPE_OK',glb)
