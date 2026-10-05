"""Garment geometry, executed by build_overalls.py in its rig context."""
N=48
def shirt_top(a):return 1.075+.150*abs(math.sin(a))**2+.065*max(0,-math.cos(a))**4
def garment_radius(z):return max(h['body_radius'](z)+.055,.36 if z<.86 else 0)
def surface(a,z,out=0):
 r=garment_radius(z)+out
 return (r*math.sin(a),-r*math.cos(a),z)
def solid(obj,thickness=.008):
 mod=obj.modifiers.new('ClothThickness','SOLIDIFY');mod.thickness=thickness;mod.offset=-1
 obj.modifiers.move(obj.modifiers.find(mod.name),0)
 return obj
def panel(name,amin,amax,lo,hi,mat,out=0,rows=14,cols=48):
 vs=[];fs=[]
 for j in range(rows+1):
  t=j/rows
  for i in range(cols+1):
   a=amin+(amax-amin)*i/cols;z=lo(a)*(1-t)+hi(a)*t
   vs.append(surface(a,z,out))
 for j in range(rows):
  for i in range(cols):
   k=j*(cols+1)+i;fs.append((k,k+1,k+cols+2,k+cols+1))
 return solid(mesh(name,vs,fs,mat,'TORSO'))
def tube(name,coords,mat,width=.002,bone='TORSO',closed=False):
 cu=bpy.data.curves.new(name,'CURVE');cu.dimensions='3D';cu.bevel_depth=width;cu.bevel_resolution=1
 sp=cu.splines.new('POLY');sp.points.add(len(coords)-1)
 for p,co in zip(sp.points,coords):p.co=(*co,1)
 sp.use_cyclic_u=closed
 ob=bpy.data.objects.new(name,cu);bpy.context.collection.objects.link(ob)
 bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob;bpy.ops.object.convert(target='MESH')
 ob.data.materials.append(mat);bind(ob,bone)
 return ob

# Remove covered belly buttons and old pink arms/cuffs from this outfit copy only.
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
 center=sum((a.co for a in group),Vector())/len(group)
 if (abs(center.x)<.12 and .63<center.z<1.22 and center.y<-.25) or (abs(center.x)>.34 and .86<center.z<1.27):remove+=group
bmesh.ops.delete(bm,geom=remove,context='VERTS');bm.to_mesh(costume.data);bm.free()

shirt=panel('CreamShirt',-math.pi,math.pi,lambda a:.74,shirt_top,cream,out=-.012,cols=N)
panel('ShirtCollar',-math.pi,math.pi,lambda a:shirt_top(a)-.017,shirt_top,cream,out=-.008,rows=2,cols=N)
for sign in [-1,1]:
 side='L' if sign>0 else 'R';loc,rot=h['arm_transform'](sign)
 sleeve=h['bake'](h['lathe']('CottonSleeve'+side,[(-.265,.099),(-.25,.111),(-.19,.116),(-.08,.120),(.025,.108),(.09,.07),(.11,0)],32),loc=loc,rot=rot)
 sleeve.data.materials.append(cream);bind(sleeve,'UpperArm.'+side);solid(sleeve)
 cuff=h['bake'](h['lathe']('SleeveHem'+side,[(-.269,.102),(-.263,.113),(-.244,.116),(-.239,.109)],32),loc=loc,rot=rot)
 cuff.data.materials.append(cream);bind(cuff,'UpperArm.'+side)

def bib_top(a):
 front=max(0,math.cos(a));back=max(0,-math.cos(a))
 return .86+.12*min(1,(front/.70)**6)+.045*back**2
bib=panel('DenimBib',-math.pi,math.pi,lambda a:.72,bib_top,denim,cols=N)
# The original tail and dorsal spikes stay visible through the rear opening.
for ob in [bib,shirt]:
 bm=bmesh.new();bm.from_mesh(ob.data)
 dead=[]
 for f in bm.faces:
  c=f.calc_center_median()
  if c.y>.25 and ((c.x/.14)**2+((c.z-.80)/.145)**2<1.1 or (abs(c.x)<.063 and c.z>.94)):dead.append(f)
 bmesh.ops.delete(bm,geom=dead,context='FACES');bm.to_mesh(ob.data);bm.free()
tube('TailBoundEdge',[(.143*math.cos(a),math.sqrt(garment_radius(.80+.147*math.sin(a))**2-(.143*math.cos(a))**2)+.006,.80+.147*math.sin(a)) for a in [i/N*math.tau for i in range(N)]],denim,.009,closed=True)
tube('BibTopSeam',[surface(a,bib_top(a)-.010,.003) for a in [i/N*math.tau for i in range(N+1)]],thread,.0015)

# Shoulder straps follow the shirt surface instead of widening the entire torso.
for sign in [-1,1]:
 vs=[];fs=[];rows=48;cols=4
 def strap(t,offset):
  angle_rate=sign*(math.pi+.52-.78)
  height_rate=.285*math.pi*math.cos(math.pi*t)-.08
  length=math.hypot(angle_rate*.44,height_rate)
  a=sign*(.78+(math.pi+.52-.78)*t)-offset*height_rate/length
  z=.980+.285*math.sin(math.pi*t)-.08*t+offset*angle_rate*.44*.44/length
  return surface(a,z,.006+(0.005 if sign<0 and t>.72 else 0))
 for j in range(rows+1):
  for i in range(cols+1):vs.append(strap(j/rows,(i/cols-.5)*.185))
 for j in range(rows):
  for i in range(cols):
   k=j*(cols+1)+i;fs.append((k,k+1,k+cols+2,k+cols+1))
 solid(mesh('ShoulderStrap'+str(sign),vs,fs,denim,'TORSO'))
 for offset in [-.074,.074]:
  coords=[]
  for j in range(rows+1):
   v=Vector(strap(j/rows,offset));v+=Vector((v.x,v.y,0)).normalized()*.002
   coords.append(v)
  tube('StrapStitch',coords,thread,.0012)
 pos=Vector(surface(sign*.78,.980,.023))
 button=h['ball']('GoldFastener'+str(sign),pos,(.043,.015,.043),rot=(0,0,sign*.60))
 button.data.materials.append(gold);bind(button,'TORSO')

# Two continuous short legs with rolled cuffs, smoothly weighted across the hip.
def pants_point(sign,a,z,out=0):
 t=max(0,min(1,(.72-z)/.27))
 x=(1-t)*(garment_radius(.72)*max(0,math.sin(a)))+t*(h['HIP_X']+.171*math.sin(a))
 y=((1-t)*garment_radius(.72)+t*.265)*math.cos(a)
 z-=(1-t)*.21*max(0,-math.sin(a))
 return(sign*(x+out*math.sin(a)),y+out*math.cos(a),z)
for sign in [-1,1]:
 side='L' if sign>0 else 'R'
 for name,z0,z1,mat,out in [('DenimShorts',.72,.45,denim,0),('RolledCuff',.489,.446,cuff_mat,.007)]:
  vs=[];fs=[];rows=12 if name=='DenimShorts' else 3
  for j in range(rows+1):
   z=z0+(z1-z0)*j/rows
   for i in range(N):vs.append(pants_point(sign,i/N*math.tau,z,out))
  for j in range(rows):
   for i in range(N):
    k=j*N+i;n=j*N+(i+1)%N;fs.append((k,n,n+N,k+N))
  ob=mesh(name+side,vs,[tuple(reversed(f)) for f in fs] if sign<0 else fs,mat,'PANTS.'+side)
  # Both sides of the crotch seam have exactly the same hip weights.
  for j in range(rows+1):
   hip=(1-j/rows) if name=='DenimShorts' else 0.0
   hip=hip*hip*(3-2*hip)
   for bone,w in [('Hips',hip),('Thigh.'+side,1-hip)]:
    ob.vertex_groups[bone].add(list(range(j*N,(j+1)*N)),w,'REPLACE')
  solid(ob)
  sub=ob.modifiers.new('SoftCloth','SUBSURF');sub.levels=1
  ob.modifiers.move(ob.modifiers.find(sub.name),0)
 tube('LegSideSeam'+side,[pants_point(sign,math.pi/2,.72-.23*j/24,.004) for j in range(25)],thread,.0014,'PANTS.'+side)

def pocket(name,ac,zc,width,height):
 # The bottom corners curve upward; all faces follow the torso rather than a flat decal.
 def lower(a):
  u=abs((a-ac)/(width/2));return zc-height/2+.025*u**6
 p=panel(name,ac-width/2,ac+width/2,lower,lambda a:zc+height/2,denim,out=.010,rows=12,cols=28)
 coords=[surface(ac-width/2+.017,zc+height/2-height*j/24+.018,.014) for j in range(22)]
 coords+=[surface(ac-width/2+width*j/32,lower(ac-width/2+width*j/32)+.010,.014) for j in range(33)]
 coords+=[surface(ac+width/2-.017,zc-height/2+.018+height*j/24,.014) for j in range(3,25)]
 tube(name+'Stitch',coords,thread,.0014)
 tube(name+'Top',[surface(ac-width/2+width*j/32,zc+height/2-.009,.014) for j in range(33)],thread,.0015)
pocket('ChestPocket',0,.873,.80,.18)
for sign in [-1,1]:pocket('RearPocket'+str(sign),math.pi+sign*.62,.775,.50,.14)

# Keep both complete leg components. A height test on face centers used to
# remove the entire ring spanning the shorts hem and left the leg visibly cut.
bm=bmesh.new();bm.from_mesh(body.data);dead=[]
seen=set();leg_vertices=set()
for seed in bm.verts:
 if seed in seen:continue
 component={seed};stack=[seed];seen.add(seed)
 while stack:
  for edge in stack.pop().link_edges:
   for vertex in edge.verts:
    if vertex not in seen:seen.add(vertex);component.add(vertex);stack.append(vertex)
 zmin=min(v.co.z for v in component);zmax=max(v.co.z for v in component)
 if zmin<.10 and .60<zmax<.70:leg_vertices.update(component)
assert len(leg_vertices)==260, 'Expected both original 130-vertex leg components'
for f in bm.faces:
 if all(v in leg_vertices for v in f.verts):continue
 c=f.calc_center_median();a=math.atan2(c.x,-c.y)
 torso=.50<c.z<shirt_top(a)-.020 and c.x*c.x+c.y*c.y<.44**2
 tail=c.y>.28 and abs(c.x)<.17 and .64<c.z<.96
 if torso and not tail:dead.append(f)
bmesh.ops.delete(bm,geom=dead,context='FACES');bm.to_mesh(body.data);bm.free()

# Join and weld the waist boundary: the bib and shorts are one continuous garment.
parts=[bib,bpy.data.objects['DenimShortsL'],bpy.data.objects['DenimShortsR']]
for ob in parts:
 bpy.context.view_layer.objects.active=ob
 for mod in list(ob.modifiers):
  if mod.type=='SUBSURF':ob.modifiers.remove(mod)
  elif mod.type=='SOLIDIFY':ob.modifiers.remove(mod)
bpy.ops.object.select_all(action='DESELECT')
for ob in parts:ob.select_set(True)
bpy.context.view_layer.objects.active=bib;bpy.ops.object.join();bib.name='DenimOveralls'
bm=bmesh.new();bm.from_mesh(bib.data)
bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00015)
bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(bib.data);bm.free()
sub=bib.modifiers.new('ContinuousCloth','SUBSURF');sub.levels=1;bib.modifiers.move(bib.modifiers.find(sub.name),0)
solid(bib)
