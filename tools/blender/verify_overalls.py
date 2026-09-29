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

# Regression: actual faces, not just loose vertices, must survive at both hems.
leg_vertices=set();visited=set()
for seed in adj:
 if seed in visited:continue
 component={seed};todo=[seed];visited.add(seed)
 while todo:
  for index in adj[todo.pop()]:
   if index not in visited:visited.add(index);component.add(index);todo.append(index)
 z=[body.data.vertices[i].co.z for i in component]
 if min(z)<.10 and .60<max(z)<.70:leg_vertices.update(component)
assert len(leg_vertices)==260
leg_faces={tuple(sorted(coordinate(body.data.vertices[i]) for i in p.vertices)) for p in body.data.polygons if all(i in leg_vertices for i in p.vertices)}
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
bpy.ops.wm.open_mainfile(filepath=str(HERE/'overalls.blend'))
body=bpy.data.objects['Body'];rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
retained_faces={tuple(sorted(coordinate(body.data.vertices[i]) for i in p.vertices)) for p in body.data.polygons}
assert leg_faces<=retained_faces, 'Leg surfaces removed at shorts hem: %d missing faces' % len(leg_faces-retained_faces)
assert tail<={coordinate(v) for v in body.data.vertices},'Tail geometry changed'
assert face==[coordinate(v) for v in bpy.data.objects['Face'].data.vertices],'Face geometry changed'
assert bones=={b.name:[round(v,6) for row in b.matrix_local for v in row] for b in rig.data.bones},'Rest skeleton changed'
assert clips=={t.strips[0].action.name for t in rig.animation_data.nla_tracks if t.strips},'Animation missing'
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
result['complete_leg_faces_preserved']=len(leg_faces)
(HERE/'preview/overalls/structural_validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print('OVERALLS STRUCTURE: ALL OK',result)
