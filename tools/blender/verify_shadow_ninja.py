"""Read-only checks of original dinosaur versus the independent outfit blend."""
import bpy, json
from pathlib import Path
HERE=Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(HERE/'fallguy.blend'))
body=bpy.data.objects['Body']
adj={v.index:[] for v in body.data.vertices}
for edge in body.data.edges:
 a,b=edge.vertices;adj[a].append(b);adj[b].append(a)
seed=max(body.data.vertices,key=lambda v:v.co.y).index
seen={seed};stack=[seed]
while stack:
 for neighbor in adj[stack.pop()]:
  if neighbor not in seen:seen.add(neighbor);stack.append(neighbor)
def coordinate(v):return tuple(round(c,6) for c in v.co)

def animation_signatures(rig):
 result={}
 for track in rig.animation_data.nla_tracks:
  for nla in track.strips:
   action=nla.action;curves=[]
   for layer in action.layers:
    for strip in layer.strips:
     for bag in strip.channelbags:
      for curve in bag.fcurves:
       keys=[(tuple(k.co),tuple(k.handle_left),tuple(k.handle_right),k.interpolation,k.handle_left_type,k.handle_right_type) for k in curve.keyframe_points]
       curves.append((curve.data_path,curve.array_index,curve.extrapolation,keys))
   result[action.name]={'curves':sorted(curves),'strip':(nla.frame_start,nla.frame_end,nla.action_frame_start,nla.action_frame_end,nla.scale,nla.repeat,nla.blend_type,nla.extrapolation)}
 return result

def protected_spikes(mesh):
 adjacency={v.index:[] for v in mesh.vertices}
 for e in mesh.edges:
  a,b=e.vertices;adjacency[a].append(b);adjacency[b].append(a)
 seen=set();protected=set();count=0
 for seed in adjacency:
  if seed in seen:continue
  group={seed};stack=[seed];seen.add(seed)
  while stack:
   for i in adjacency[stack.pop()]:
    if i not in seen:seen.add(i);group.add(i);stack.append(i)
  ys=[mesh.vertices[i].co.y for i in group];zs=[mesh.vertices[i].co.z for i in group]
  if (sum(ys)/len(ys)>.15 and sum(zs)/len(zs)>.60) or sum(zs)/len(zs)>1.50:
   protected.update(coordinate(mesh.vertices[i]) for i in group);count+=1
 return protected,count
tail={coordinate(body.data.vertices[i]) for i in seen}
face=[coordinate(v) for v in bpy.data.objects['Face'].data.vertices]
rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
bones={b.name:[round(v,6) for row in b.matrix_local for v in row] for b in rig.data.bones}
original_weights={}
for name in ['Body','Costume','Face']:
 ob=bpy.data.objects[name];original_weights[name]={}
 for v in ob.data.vertices:
  w=tuple(sorted((ob.vertex_groups[g.group].name,round(g.weight,6)) for g in v.groups))
  original_weights[name].setdefault(coordinate(v),set()).add(w)
clips={t.strips[0].action.name for t in rig.animation_data.nla_tracks if t.strips}
animations=animation_signatures(rig)
spikes,spike_components=protected_spikes(bpy.data.objects['Costume'].data)
assert spike_components>=8,'Source dorsal spikes were not identified'
bpy.ops.wm.open_mainfile(filepath=str(HERE/'shadow_ninja.blend'))
body=bpy.data.objects['Body'];rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
assert tail<={coordinate(v) for v in body.data.vertices},'Tail geometry changed'
assert face==[coordinate(v) for v in bpy.data.objects['Face'].data.vertices],'Face geometry changed'
assert bones=={b.name:[round(v,6) for row in b.matrix_local for v in row] for b in rig.data.bones},'Rest skeleton changed'
assert clips=={t.strips[0].action.name for t in rig.animation_data.nla_tracks if t.strips},'Animation missing'
assert animations==animation_signatures(rig),'Animation keyframes or NLA timing changed'
assert spikes<={coordinate(v) for v in bpy.data.objects['Costume'].data.vertices},'Dorsal spike geometry changed'
bad=[]
for ob in bpy.data.objects:
 if ob.type!='MESH' or ob.parent!=rig:continue
 used={i for face in ob.data.polygons for i in face.vertices}
 for v in ob.data.vertices:
  if v.index not in used:continue
  if ob.name in original_weights:
   w=tuple(sorted((ob.vertex_groups[g.group].name,round(g.weight,6)) for g in v.groups))
   assert w in original_weights[ob.name][coordinate(v)],'Original character weights changed'
   continue
  total=sum(g.weight for g in v.groups if ob.vertex_groups[g.group].name in bones)
  if abs(total-1)>0.002:bad.append([ob.name,v.index,total])
assert not bad, str(bad[:10])
result={'tail_component_vertices_preserved':len(tail),'face_vertices_preserved':len(face),'rest_bones_preserved':len(bones),'animation_names_preserved':sorted(clips),'garment_weights_normalized':True,'original_character_weights_preserved':True}
result.update({'animation_keyframes_and_nla_timing_preserved':True,'dorsal_spike_components_preserved':spike_components,'dorsal_spike_vertices_preserved':len(spikes)})
(HERE/'preview/shadow_ninja/structural_validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print('SHADOW NINJA STRUCTURE: ALL OK',result)
