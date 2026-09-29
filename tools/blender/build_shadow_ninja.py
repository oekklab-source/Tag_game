"""黒影忍者。既存恐竜のリグと動作を保持して独立した衣装GLBを生成する。"""
import math, sys, json
from pathlib import Path
import bpy, bmesh
from mathutils import Vector, Euler
from mathutils.kdtree import KDTree
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from prototype_slide import load_helpers, set_action
h=load_helpers()
OUT=HERE/'preview/shadow_ninja';OUT.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(HERE/'fallguy.blend'))
rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
body=bpy.data.objects['Body']
rig.animation_data.action=None
for t in rig.animation_data.nla_tracks:t.mute=True
h['apply_pose'](rig,{})
bpy.context.scene.frame_set(0)
kd=KDTree(len(body.data.vertices))
for v in body.data.vertices:kd.insert(v.co,v.index)
kd.balance()

def material(name,rgb,metal=0):
 c=tuple(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in rgb)
 m=bpy.data.materials.new(name);m.diffuse_color=(*c,1);m.use_nodes=True
 p=next(n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED');p.inputs['Base Color'].default_value=(*c,1)
 p.inputs['Roughness'].default_value=.8 if not metal else .36
 p.inputs['Metallic'].default_value=metal
 return m
cloth=material('ShadowCharcoal',(.19,.20,.23))
dark=material('ShadowMask',(.115,.125,.15))
purple=material('ShadowPurple',(.36,.21,.51))
edge=material('ShadowPurpleEdge',(.46,.29,.63))
silver=material('ShadowSilver',(.72,.74,.77),.65)
body.data.materials.clear();body.data.materials.append(material('ShadowDinosaurGreen',(.20,.61,.28)))
# Convert inherited bright/emissive materials to the reference's soft matte palette.
for name,color in {'Skin':(.96,.73,.77),'FaceWhite':(.98,.97,.96),'Pupil':(.045,.052,.085),'Claw':(.95,.95,.90),'SpikeYellow':(.97,.83,.40),'SpikePurple':(.75,.60,.91),'SpikeBlue':(.52,.77,.91)}.items():
 old=bpy.data.materials.get(name)
 if old:
  new=material('Shadow'+name,color)
  for ob in bpy.data.objects:
   if ob.type=='MESH':
    for slot in ob.material_slots:
     if slot.material==old:slot.material=new

def bind(ob,bone=None):
 for v in ob.data.vertices:
  if bone=='TORSO':
   chest=max(0,min(1,(v.co.z-.98)/.20));spine=(1-chest)*max(0,min(1,(v.co.z-.80)/.18))
   weights={'Hips':1-chest-spine,'Spine':spine,'Chest':chest}
  elif bone and bone.startswith('PANTS.'):
   t=max(0,min(1,(v.co.z-.47)/.24));t=t*t*(3-2*t)
   weights={'Hips':t,'Thigh.'+bone[-1]:1-t}
  elif bone:weights={bone:1}
  else:
   _,idx,_=kd.find(v.co)
   weights={body.vertex_groups[g.group].name:g.weight for g in body.data.vertices[idx].groups}
  total=sum(weights.values())
  weights={name:w/total for name,w in weights.items()}
  for name,w in weights.items():
   g=ob.vertex_groups.get(name) or ob.vertex_groups.new(name=name);g.add([v.index],w,'REPLACE')
 ob.parent=rig;mod=ob.modifiers.new('OutfitRig','ARMATURE');mod.object=rig
 for p in ob.data.polygons:p.use_smooth=True
 return ob

def mesh(name,vs,fs,mat,bone='TORSO',thick=.008):
 data=bpy.data.meshes.new(name);data.from_pydata(vs,[],fs);data.update()
 ob=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(ob);data.materials.append(mat)
 bm=bmesh.new();bm.from_mesh(data);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(data);bm.free()
 if thick:
  mod=ob.modifiers.new('FabricThickness','SOLIDIFY');mod.thickness=thick;mod.offset=-1
  bevel=ob.modifiers.new('SoftFabricEdges','BEVEL');bevel.width=.005;bevel.segments=3
 return bind(ob,bone)

def ball(name,pos,scale,mat,bone='TORSO'):
 ob=h['ball'](name,pos,scale,segments=24);ob.data.materials.append(mat);return bind(ob,bone)

def surface(a,z,out=.045):
 r=h['body_radius'](z)+out
 return (r*math.sin(a),-r*math.cos(a),z)

def panel(name,lo,hi,mat,out=.045,amin=-math.pi,amax=math.pi,bone='TORSO',rows=20,cols=64,tail=False):
 vs=[];fs=[]
 for j in range(rows+1):
  for i in range(cols+1):
   a=amin+(amax-amin)*i/cols;z=lo(a)+(hi(a)-lo(a))*j/rows;vs.append(surface(a,z,out(a,j/rows) if callable(out) else out))
 for j in range(rows):
  for i in range(cols):
   k=j*(cols+1)+i;f=(k,k+1,k+cols+2,k+cols+1);c=sum((Vector(vs[x]) for x in f),Vector())/4
   if tail and c.y>.25 and (c.x/.145)**2+((c.z-.80)/.145)**2<1.15:continue
   fs.append(f)
 return mesh(name,vs,fs,mat,bone)

def ribbon(name,points,width,mat,bone='TORSO',axis=(0,0,1)):
 vs=[];fs=[];axis=Vector(axis);ring=8
 for i,p in enumerate(points):
  v=Vector(p);t=i/(len(points)-1)
  tangent=(Vector(points[min(i+1,len(points)-1)])-Vector(points[max(0,i-1)])).normalized()
  cross=(axis-tangent*axis.dot(tangent)).normalized();normal=tangent.cross(cross).normalized()
  cap=.45 if i in [0,len(points)-1] else 1
  w=width*(.90+.10*math.sin(math.pi*t))*cap
  for j in range(ring):
   a=j/ring*math.tau;vs.append(v+cross*(w*.5*math.cos(a))+normal*(.006*math.sin(a)))
  if i:
   for j in range(ring):
    k=i*ring+j;n=i*ring+(j+1)%ring;fs.append((k-ring,n-ring,n,k))
 fs.extend([tuple(reversed(range(ring))),tuple((len(points)-1)*ring+j for j in range(ring))])
 return mesh(name,vs,fs,mat,bone,0)

# Remove old pink sleeves, cuffs and front belly buttons in the costume copy.
costume=bpy.data.objects['Costume'];bm=bmesh.new();bm.from_mesh(costume.data)
seen=set();remove=[]
for v in bm.verts:
 if v in seen:continue
 stack=[v];group=[];seen.add(v)
 while stack:
  a=stack.pop();group.append(a)
  for e in a.link_edges:
   b=e.other_vert(a)
   if b not in seen:seen.add(b);stack.append(b)
 c=sum((a.co for a in group),Vector())/len(group)
 if (abs(c.x)<.12 and .63<c.z<1.22 and c.y<-.25) or (abs(c.x)>.34 and .86<c.z<1.27):remove+=group
bmesh.ops.delete(bm,geom=remove,context='VERTS');bm.to_mesh(costume.data);bm.free()

def jacket_lower(a):
 x=.44*math.sin(a)
 if math.cos(a)<0 and abs(x)<.155:return .80+.15*math.sqrt(max(0,1-(x/.155)**2))
 return .665+.02*math.cos(a)
panel('Jacket',jacket_lower,lambda a:1.12+.07*abs(math.sin(a)),cloth)
panel('JacketHem',jacket_lower,lambda a:jacket_lower(a)+.014,dark,out=.049,rows=2)
# Wrap-front flap continues below the belt with a diagonal hem, like the reference.
panel('WrapFrontFlap',lambda a:.67+.045*(a+.80)/1.60,lambda a:1.11-.025*a,cloth,out=.056,amin=-.80,amax=.80,rows=22,cols=36)
ribbon('WrapFrontHem',[surface(a,.673+.045*(a+.80)/1.60,.062) for a in [-.8+1.6*i/40 for i in range(41)]],.010,dark)
# Wraparound waist belt; the rear tail opening lies below the belt.
panel('WaistSash',lambda a:.845+.080*max(0,-math.cos(a))**12,lambda a:.91+.080*max(0,-math.cos(a))**12,purple,out=lambda a,t:.065+.012*math.sin(math.pi*t),rows=6)
ball('SashKnot',surface(.10,.875,.09),(.051,.029,.048),purple)
for side in [-1,1]:
 ribbon('SashEnd'+str(side),[surface(.10+side*.30*t,.866-.16*t,.085) for t in [i/12 for i in range(13)]],.064,purple,axis=(1,0,0))
# Diagonal overlapping lapels lie against the body instead of floating away.
for sign in [-1,1]:
 ribbon('CrossoverLapel'+str(sign),[surface(sign*(.65-1.03*t),1.145-.285*t,.059+(sign+1)*.006) for t in [i/24 for i in range(25)]],.075,purple if sign==1 else dark)

# Puffy short trousers, tapering toward the shin wraps.
for sign in [-1,1]:
 side='L' if sign>0 else 'R';vs=[];fs=[];N=40
 for j in range(13):
  t=j/12;z=.73-.38*t
  for i in range(N):
   a=i/N*math.tau
   radius=.125+.055*math.sin(math.pi*t)
   x=(1-t)*(.40*max(0,math.sin(a)))+t*(h['HIP_X']+radius*math.sin(a))
   y=((1-t)*.40+t*radius+.04*math.sin(math.pi*t))*math.cos(a)
   vs.append((sign*x,y,z-(1-t)*.21*max(0,-math.sin(a))))
 for j in range(12):
  for i in range(N):
   k=j*N+i;n=j*N+(i+1)%N;fs.append((k,n,n+N,k+N))
 pants=mesh('Pants'+side,vs,fs,cloth,'PANTS.'+side)
 for j in range(13):
  t=j/12;hip=(1-t)**2*(1+2*t)
  for name,w in [('Hips',hip),('Thigh.'+side,1-hip)]:
   pants.vertex_groups[name].add(list(range(j*N,(j+1)*N)),w,'REPLACE')
 sub=pants.modifiers.new('SoftPants','SUBSURF');sub.levels=2;pants.modifiers.move(pants.modifiers.find(sub.name),0)
 loc,rot=h['arm_transform'](sign)
 sleeve=h['bake'](h['lathe']('Sleeve'+side,[(-.28,.098),(-.25,.108),(-.16,.114),(-.04,.116),(.055,.10),(.105,.055),(.115,0)],32),loc=loc,rot=rot)
 sleeve.data.materials.append(cloth);bind(sleeve,'UpperArm.'+side)
 matrot=Euler(rot).to_matrix()
 for direction in [-1,1]:
  points=[]
  for i in range(81):
   t=i/80;a=direction*t*math.tau*1.2
   points.append(Vector(loc)+matrot@Vector((.118*math.sin(a),.118*math.cos(a),-.255+.16*t)))
  ribbon('ArmWrap'+side+str(direction),points,.020,purple,'UpperArm.'+side,tuple(matrot@Vector((0,0,1))))
 shin=h['bake'](h['lathe']('ShinGuard'+side,[(.18,.13),(.23,.138),(.32,.14),(.46,.135),(.54,.13)],32),loc=(h['HIP_X']*sign,0,0))
 shin.data.materials.append(dark);bind(shin)
 for direction in [-1,1]:
  points=[]
  for i in range(65):
   t=i/64;a=direction*t*math.tau
   points.append((h['HIP_X']*sign+.146*math.sin(a),.146*math.cos(a),.20+.19*t))
  ribbon('LegWrap'+side+str(direction),points,.021,purple,'Shin.'+side)

# The green dinosaur head remains uncovered above the separate mask and headband.
panel('Headband',lambda a:1.50+.025*max(0,math.cos(a)),lambda a:1.64,dark,out=.068,bone='Chest',rows=7)
def plate_point(x,z,out=0):return (x,-.364+.30*x*x-out,z)
vs=[];fs=[]
for j in range(5):
 for i in range(17):vs.append(plate_point(-.15+.30*i/16,1.515+.108*j/4))
for j in range(4):
 for i in range(16):
  k=j*17+i;fs.append((k,k+1,k+18,k+17))
mesh('ForeheadPlate',vs,fs,silver,'Chest',.014)
for x in [-.128,.128]:
 for z in [1.533,1.605]:ball('PlateRivet',plate_point(x,z,.010),(.008,.005,.008),dark,'Chest')
vs=[plate_point(0,1.562,.012)]
for i in range(8):
 a=i*math.pi/4;r=.035 if i%2==0 else .010
 vs.append(plate_point(math.sin(a)*r,1.562+math.cos(a)*r,.014))
mesh('FourPointEmblem',vs,[(0,i+1,(i+1)%8+1) for i in range(8)],dark,'Chest',.004)
mask_out=lambda a,t:.042+.068*max(0,math.cos(a))**4+.009*math.sin(math.pi*t)
panel('FaceMask',lambda a:1.15+.035*abs(math.sin(a)),lambda a:1.295-.020*math.cos(a),dark,out=mask_out,amin=-1.50,amax=1.50,bone='Chest',rows=12,cols=64)
panel('MaskUpperHem',lambda a:1.286-.020*math.cos(a),lambda a:1.300-.020*math.cos(a),cloth,out=lambda a,t:mask_out(a,1)+.003,amin=-1.50,amax=1.50,bone='Chest',rows=3)
scarf_out=lambda a,t:.046+.063*max(0,math.cos(a))**5+.020*math.sin(math.pi*t)
panel('PurpleScarf',lambda a:1.055+.045*abs(math.sin(a)),lambda a:1.17+.045*abs(math.sin(a)),purple,out=scarf_out,bone='Chest',rows=12)
# Crossed layers follow the reference's V-shaped scarf instead of horizontal rings.
points=[]
for i in range(97):
 a=-math.pi+math.tau*i/96
 z=1.09+.042*abs(math.sin(a))+.014*math.sin(a)
 points.append(surface(a,z,scarf_out(a,.35)+.006))
ribbon('ScarfFold',points,.023,purple,'Chest')
for side in [-1,1]:
 points=[]
 for i in range(49):
  t=i/48;a=side*(1.48-2.15*t)
  z=1.194-.107*math.sin(t*math.pi/2)+.006*side
  points.append(surface(a,z,scarf_out(a,.55)+.008+(side+1)*.006))
 ribbon('CrossedScarf'+str(side),points,.067,purple,'Chest')
ball('ScarfKnot',(.20,.40,1.12),(.064,.045,.055),purple,'Chest')
for i in range(2):
 ribbon('ScarfTail'+str(i),[(.20+.30*t,.40+.09*t,1.12+(i*.10-.03)*t+.025*math.sin(t*math.pi)) for t in [j/16 for j in range(17)]],.078,purple,'Chest')
ball('HeadbandKnot',(.20,.32,1.535),(.05,.044,.061),dark,'Chest')
for i in range(2):
 ribbon('HeadbandTail'+str(i),[(.20+.21*t,.32+.09*t,1.54+(-.10 if i else .07)*t) for t in [j/12 for j in range(13)]],.063,dark,'Chest')

# Rounded folds make the knots read as fabric, rather than a button on flat strips.
for name,center,scale,mat,bone in [
 ('SashKnotFold',surface(.12,.88,.116),(.018,.009,.042),edge,'TORSO'),
 ('HeadTieLoop',(.255,.343,1.57),(.061,.019,.042),dark,'Chest'),
 ('HeadTieLoopLower',(.257,.345,1.50),(.055,.021,.033),dark,'Chest')]:
 ball(name,center,scale,mat,bone)

# Weld the two trouser panels along their common hip seam before smoothing.
pants=[bpy.data.objects['PantsL'],bpy.data.objects['PantsR']]
for ob in pants:
 for mod in list(ob.modifiers):
  if mod.type!='ARMATURE':ob.modifiers.remove(mod)
bpy.ops.object.select_all(action='DESELECT')
for ob in pants:ob.select_set(True)
bpy.context.view_layer.objects.active=pants[0];bpy.ops.object.join()
trousers=pants[0];trousers.name='NinjaTrousers'
bm=bmesh.new();bm.from_mesh(trousers.data)
bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00015)
bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(trousers.data);bm.free()
sub=trousers.modifiers.new('SoftContinuousTrousers','SUBSURF');sub.levels=2
trousers.modifiers.move(trousers.modifiers.find(sub.name),0)
solid=trousers.modifiers.new('TrouserThickness','SOLIDIFY');solid.thickness=.008;solid.offset=-1
trousers.modifiers.move(trousers.modifiers.find(solid.name),1)

# Subtle woven cloth texture, embedded in the GLB, not a Blender-only noise shader.
for mat,rgb in [(cloth,(.19,.20,.23)),(dark,(.115,.125,.15)),(purple,(.36,.21,.51))]:
 tex=bpy.data.images.new(mat.name+'Weave',width=128,height=128,alpha=True)
 tex.colorspace_settings.name='sRGB';pixels=[]
 for y in range(128):
  for x in range(128):
   grain=1+.018*math.sin(x*math.pi/2)+.012*math.cos(y*math.pi/2)+(((x*73+y*41)%19)/18-.5)*.012
   pixels.extend([v*grain for v in rgb]+[1])
 tex.pixels=pixels;tex.pack()
 node=mat.node_tree.nodes.new('ShaderNodeTexImage');node.image=tex;node.extension='REPEAT'
 shader=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
 mat.node_tree.links.new(node.outputs['Color'],shader.inputs['Base Color'])
for ob in bpy.data.objects:
 if ob.type!='MESH' or ob.parent!=rig or not any(m in [cloth,dark,purple] for m in ob.data.materials):continue
 uv=ob.data.uv_layers.new(name='ClothUV')
 for f in ob.data.polygons:
  angles=[math.atan2(ob.data.vertices[ob.data.loops[k].vertex_index].co.x,-ob.data.vertices[ob.data.loops[k].vertex_index].co.y) for k in f.loop_indices]
  if max(angles)-min(angles)>math.pi:angles=[a+math.tau if a<0 else a for a in angles]
  for k,a in zip(f.loop_indices,angles):uv.data[k].uv=(a*2,ob.data.vertices[ob.data.loops[k].vertex_index].co.z*5)

# Delete only body faces under opaque garments; preserve original face/tail/weights.
bm=bmesh.new();bm.from_mesh(body.data);dead=[]
for f in bm.faces:
 c=f.calc_center_median()
 torso=.49<c.z<1.10 and c.x*c.x+c.y*c.y<.44**2
 tail=c.y>.28 and abs(c.x)<.17 and .64<c.z<.96
 legs=.23<c.z<.65 and abs(c.x)<.34 and abs(c.y)<.12
 if (torso and not tail) or legs:dead.append(f)
bmesh.ops.delete(bm,geom=dead,context='FACES');bm.to_mesh(body.data);bm.free()
for t in rig.animation_data.nla_tracks:t.mute=False
rig.animation_data.action=None
bpy.context.scene.frame_set(0)
bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'shadow_ninja.blend'))
glb=HERE.parent.parent/'assets/character/outfits/shadow_ninja.glb'
bpy.ops.export_scene.gltf(filepath=str(glb),export_format='GLB',export_yup=True,export_apply=True,export_skins=True,export_rest_position_armature=True,export_animations=True,export_animation_mode='NLA_TRACKS',export_bake_animation=False,export_optimize_animation_size=False,export_cameras=False,export_lights=False)
print('SHADOW NINJA BUILD OK',glb)
