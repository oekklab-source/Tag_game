class_name CpuNavAssist
extends RefCounted

## CPU がナビリンク任せでギミック入口に引っかからないよう、
## 滑り台やジャンプボードへ明示的に誘導する。

const SLIDE_APPROACH_INSET := 3.0
const SLIDE_DIRECT_RADIUS := 6.0
const SLIDE_ENTRY_CAPTURE_RADIUS := 9.0
const SPRING_DIRECT_RADIUS := 2.2
const SPRING_CAPTURE_RADIUS := 8.0
const SPRING_AIRBORNE_HEIGHT := 2.0
const BUMPER_AVOID_LOOKAHEAD := 7.0
const BUMPER_AVOID_RADIUS := 4.5
const BUMPER_AVOID_WEIGHT := 1.5


static func slide_assist(pos: Vector3, final_goal: Vector3) -> Dictionary:
	var spring := _spring_assist(pos, final_goal)
	if spring["active"]:
		return spring

	var from_zone := WorldData.zone_index(pos)
	var to_zone := WorldData.zone_index(final_goal)
	for e in WorldData.SLIDES:
		if e[1] != to_zone:
			continue
		var pts := _slide_path(e)
		var entry: Vector3 = pts[0]
		var exit: Vector3 = pts[2]
		var high_enough := pos.y > WorldData.ZONE_GROUND[e[1]] + 1.0
		var near_entry := _xz_dist(pos, entry) <= SLIDE_ENTRY_CAPTURE_RADIUS
		if e[0] != from_zone and not (high_enough and near_entry):
			continue
		var inward := entry - pts[1]
		inward.y = 0.0
		inward = inward.normalized() if inward.length() > 0.01 else Vector3.ZERO
		var approach := entry + inward * SLIDE_APPROACH_INSET
		if _xz_dist(pos, entry) <= SLIDE_DIRECT_RADIUS:
			return {"active": true, "target": exit, "direct": true}
		return {"active": true, "target": approach, "direct": false}
	return {"active": false, "target": final_goal, "direct": false}


static func _spring_assist(pos: Vector3, final_goal: Vector3) -> Dictionary:
	var from_zone := WorldData.zone_index(pos)
	var to_zone := WorldData.zone_index(final_goal)
	for e in WorldData.SPRING_PADS:
		if e[3] != to_zone:
			continue
		var source_zone: int = e[0]
		var pad := WorldData.zone_point(source_zone, e[1], e[2])
		var pad_dist := _xz_dist(pos, pad)
		var source_ground: float = WorldData.ZONE_GROUND[source_zone]
		var target_ground: float = WorldData.ZONE_GROUND[to_zone]
		var launched := from_zone == source_zone \
			and pos.y > source_ground + SPRING_AIRBORNE_HEIGHT \
			and pos.y < target_ground + SPRING_AIRBORNE_HEIGHT
		if launched:
			return {"active": true, "target": final_goal, "direct": true}
		if from_zone != source_zone and not (pad_dist <= SPRING_CAPTURE_RADIUS and pos.y < target_ground):
			continue
		if pad_dist <= SPRING_DIRECT_RADIUS:
			return {"active": true, "target": pad, "direct": true}
		return {"active": true, "target": pad, "direct": false}
	return {"active": false, "target": final_goal, "direct": false}

static func _slide_path(e: Array) -> Array[Vector3]:
	var hi: int = e[0]
	var lo: int = e[1]
	var offset: float = e[2]
	var along_x := WorldData.ZONE_COL[hi] != WorldData.ZONE_COL[lo]
	var ai := _low_side_index(hi, along_x)
	var bi := _low_side_index(lo, along_x)
	var boundary := -WorldData.BAND if mini(ai, bi) == 0 else WorldData.BAND
	var dir := 1.0 if bi > ai else -1.0
	var start := boundary + dir * WorldBuilder.SEAM_OVERLAP
	var ya: float = WorldData.ZONE_GROUND[hi]
	var yb: float = WorldData.ZONE_GROUND[lo]
	var run := maxf(WorldBuilder.SLIDE_MIN_RUN, absf(ya - yb) * WorldBuilder.SLIDE_RUN_PER_RISE)
	var perp_center: float = WorldData.AXIS_CENTER[
		WorldData.ZONE_ROW[hi] if along_x else WorldData.ZONE_COL[hi]]
	var perp := perp_center + offset
	return [
		_slide_point(along_x, start, perp, ya),
		_slide_point(along_x, start + dir * run, perp, yb),
		_slide_point(along_x, start + dir * (run + WorldBuilder.SLIDE_EXIT_RUN), perp, yb),
	]


static func _slide_point(along_x: bool, along: float, across: float, y: float) -> Vector3:
	return Vector3(along, y, across) if along_x else Vector3(across, y, along)


static func _low_side_index(zone: int, along_x: bool) -> int:
	return WorldData.ZONE_COL[zone] if along_x else WorldData.ZONE_ROW[zone]


static func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func avoid_bumpers(pos: Vector3, dir: Vector3, tree: SceneTree) -> Vector3:
	dir.y = 0.0
	if tree == null or dir.length_squared() < 0.01:
		return dir
	var forward := dir.normalized()
	var steer := forward
	for n in tree.get_nodes_in_group("cpu_bumpers"):
		var bumper := n as Node3D
		if bumper == null:
			continue
		var to_bumper := bumper.global_position - pos
		to_bumper.y = 0.0
		var ahead := to_bumper.dot(forward)
		if ahead <= 0.0 or ahead > BUMPER_AVOID_LOOKAHEAD:
			continue
		var side_vec := to_bumper - forward * ahead
		var side_dist := side_vec.length()
		if side_dist > BUMPER_AVOID_RADIUS:
			continue
		var away := -side_vec.normalized() if side_dist > 0.05 else Vector3(-forward.z, 0.0, forward.x)
		var strength := (1.0 - side_dist / BUMPER_AVOID_RADIUS) \
			* (1.0 - ahead / BUMPER_AVOID_LOOKAHEAD) * BUMPER_AVOID_WEIGHT
		steer += away * strength
	return steer.normalized() if steer.length_squared() > 0.01 else forward
