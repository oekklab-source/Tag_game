extends Node3D

## Blender 製の Fall Guys 風ちびキャラ（元データ: tools/blender/fallguy.blend）。
## プレイヤーと CPU 鬼で共用。移動速度・接地・ダイブ状態からアニメを切り替える。
## 役割色（Runner=緑 / Hunter=赤 / 待機=灰）とコスチューム（④）を部位ごとに塗り分ける。

## Run アニメを等倍で再生したとき、キャラが実際に歩く速度。
## 1周期 0.8秒で 1周期ぶんの歩幅を進むので、この値で割った倍率で再生すれば
## 「足が地面を蹴った距離」と「実際に進んだ距離」が一致する（＝足がすべらない）。
##
## この値は手計算せず tests/anim_stride.tscn で実測する。
## ボーンのローカル軸は Blender と glTF で向きが変わるため、
## ポーズの角度から求めようとすると必ず間違える
const NATURAL_SPEED := 2.42

## 再生倍率の上限。歩幅は脚の長さで頭打ちになる（このキャラは全高1.74mで
## 脚は0.56mしかない）ので、10.5m/s のダッシュに完全に比例させると
## 毎秒11歩になって脚がブレる。ここで頭打ちにした分だけ足はすべる。
##
## 通常速度 7.0m/s に必要な倍率は 2.90 なので、歩き・走りでは足はすべらない。
## すべるのはダッシュ中だけ（必要 4.35 に対して 3.6 = 約2割）
const SCALE_MAX := 3.6
const SCALE_MIN := 0.55

## Idle と Run を行き来する閾値。行きと戻りで差を付けないと、
## 閾値ぎわで毎フレーム切り替わってガタガタになる
const WALK_ENTER := 0.9
const WALK_EXIT := 0.45

## 速度の平滑化 /秒。ネットワーク越しの推定値は到着間隔のばらつきで跳ねるので、
## そのまま再生倍率にすると脚の回転が痙攣する。exp 減衰なのでフレームレート非依存
const SPEED_SMOOTH := 14.0

const BLEND := 0.15  # アニメ切り替えのクロスフェード秒
const LOOPING := ["Idle", "Run", "Jump"]

## ④役割色を弱く混ぜる比率（0=コスチューム色そのまま, 1=役割色そのまま）。
## role_tint に指定していない面（コスチュームの個性を出す面）にも少しだけ役割色を
## 混ぜることで、コスチュームが変わっても鬼/逃走者の識別性を保つ。この定数1つで
## 「見分けやすさ ↔ コスチュームらしさ」を調整できる
const ROLE_TINT_BLEND := 0.35

## fallguy.glb の実構造に合わせた対象パーツ（CostumeCatalog.PART_SURFACES と対応）
const PARTS := ["Body", "Costume", "Face"]

var _diving := false
var _state := ""
var _speed := 0.0

var _mesh_nodes := {}       # "Body" -> MeshInstance3D
var _override_keys := []    # 直前に material_override をセットした "Body:0" 等のキー（切替時のクリア用）
var _costume_id: StringName = CostumeCatalog.DEFAULT_ID
var _costume_colors := PackedColorArray()
var _role_color := Color(0.5, 0.55, 0.6)

## ⑤帽子（新規ジオメトリの部位）。apply_costume() が既存サーフェスの塗り分けだけを
## 扱うのに対し、こちらはメッシュそのものの追加/削除を扱う。責務を分けることで
## 色レシピと部位装備を独立に組み合わせられる
var _hat_id: StringName = HatCatalog.DEFAULT_ID
var _hat_instance: Node3D = null

@onready var _anim: AnimationPlayer = $Model.find_child("AnimationPlayer", true, false)
@onready var _hat_attachment: BoneAttachment3D = $Model.find_child("HatAttachment", true, false)


func _ready() -> void:
	# glTF のアニメは既定でワンショット扱いなので、ループするものだけ設定し直す
	for anim_name in LOOPING:
		var anim := _anim.get_animation(anim_name)
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR
	for part in PARTS:
		var node: MeshInstance3D = $Model.find_child(part, true, false)
		if node:
			_mesh_nodes[part] = node
	apply_costume(CostumeCatalog.DEFAULT_ID, CostumeCatalog.default_colors(CostumeCatalog.DEFAULT_ID))
	apply_hat(HatCatalog.DEFAULT_ID)
	_play("Idle")


## ④コスチューム（部位ごとの塗り分けレシピ）を適用する。
## CostumeCatalog.COSTUMES[id]["surfaces"] に載っていない面は glTF インポート時の
## 元マテリアルのまま変更しない（material_override は全 surface に効くため、
## 個別の面だけ塗り分けるには set_surface_override_material() で面ごとに扱う必要がある）
func apply_costume(id: StringName, colors: PackedColorArray) -> void:
	for key in _override_keys:
		var seg: PackedStringArray = key.split(":")
		var node: MeshInstance3D = _mesh_nodes.get(seg[0])
		if node:
			node.set_surface_override_material(int(seg[1]), null)
	_override_keys.clear()

	_costume_id = id if CostumeCatalog.has(id) else CostumeCatalog.DEFAULT_ID
	_costume_colors = colors

	var def: Dictionary = CostumeCatalog.get_def(_costume_id)
	for surf in def.get("surfaces", []):
		var part: String = surf["part"]
		var index: int = surf["index"]
		var node: MeshInstance3D = _mesh_nodes.get(part)
		if node == null or node.mesh == null or index >= node.mesh.get_surface_count():
			continue
		var mat := StandardMaterial3D.new()
		var color := _surface_color(surf)
		mat.albedo_color = color
		if surf.get("emission", false):
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = 0.6
		if surf.has("metallic"):
			mat.metallic = float(surf["metallic"])
			mat.roughness = 0.35
		node.set_surface_override_material(index, mat)
		_override_keys.append("%s:%d" % [part, index])

	# 役割色の反映（role_tint 面は強制上書き、それ以外は弱くブレンド）を、生成直後の
	# 全マテリアルに対して一貫して適用する。ここを省くと non-role_tint 面だけ
	# ブレンド無しのコスチューム地色のまま残り、set_role_color() を経由する
	# パス（自分のロール変更時）とコスチューム再適用パス（他ピアの更新受信時）とで
	# 見た目が食い違ってしまう
	set_role_color(_role_color)


## ⑤頭部装備（新規ジオメトリ、スキニング無しの剛体アタッチ）を差し替える。
## HatCatalog の各エントリは Chest ボーン(HatAttachment)基準のローカル
## position/rotation_degrees を持つ（実測値、机上計算では出せない）
func apply_hat(id: StringName) -> void:
	if _hat_instance:
		_hat_instance.queue_free()
		_hat_instance = null
	_hat_id = id if HatCatalog.has(id) else HatCatalog.DEFAULT_ID
	var def: Dictionary = HatCatalog.get_def(_hat_id)
	var packed: PackedScene = def.get("scene")
	if packed == null or _hat_attachment == null:
		return
	var inst: Node3D = packed.instantiate()
	inst.position = def.get("offset", Vector3.ZERO)
	inst.rotation_degrees = def.get("rotation_degrees", Vector3.ZERO)
	_hat_attachment.add_child(inst)
	_hat_instance = inst


func _surface_color(surf: Dictionary) -> Color:
	if surf.has("slot"):
		var slot: int = surf["slot"]
		if slot < _costume_colors.size():
			return _costume_colors[slot]
	return surf.get("albedo", Color(0.5, 0.55, 0.6))


## 親（player / cpu_hunter）が役割（Runner=緑 / Hunter=赤 / 待機=灰）に応じて呼ぶ。
## role_tint 指定の面（既定は体のみ）は常にこの色で強制上書きし、鬼/逃走者の
## 識別性を絶対に壊さない。それ以外の面（コスチュームの個性を出す面）にも
## ROLE_TINT_BLEND だけ弱く混ぜて、遠目でも見分けやすさを補強する
func set_role_color(color: Color) -> void:
	_role_color = color
	var def: Dictionary = CostumeCatalog.get_def(_costume_id)
	for surf in def.get("surfaces", []):
		var part: String = surf["part"]
		var index: int = surf["index"]
		var node: MeshInstance3D = _mesh_nodes.get(part)
		if node == null:
			continue
		var mat := node.get_surface_override_material(index) as StandardMaterial3D
		if mat == null:
			continue
		if surf.get("role_tint", false):
			_apply_role_tint(mat, color)
		else:
			mat.albedo_color = _surface_color(surf).lerp(color, ROLE_TINT_BLEND)


func _apply_role_tint(mat: StandardMaterial3D, color: Color) -> void:
	# 広くてカラフルなマップで床に埋もれないよう、弱く自己発光させる
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35


## 旧API互換（既存の呼び出し元から段階的に set_role_color へ移行するための委譲）
func set_color(color: Color) -> void:
	set_role_color(color)


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す。
##
## speed は「実際の velocity（権威ピア）」か「同期値の変化から求めた推定（他ピア）」。
## 描画フレームごとの位置差分から出してはいけない。描画が物理より速いと
## 差分ゼロのフレームが混ざり、Idle と Run が交互に出てガタガタになる
func update_motion(speed: float, on_floor: bool, delta: float) -> void:
	_speed = lerpf(_speed, speed, 1.0 - exp(-delta * SPEED_SMOOTH))
	if _diving:
		_play("Dive")
		return
	if not on_floor:
		_play("Jump")
		return
	# 立ち止まる閾値だけ低くして、境目での往復を防ぐ
	if _speed > (WALK_EXIT if _state == "Run" else WALK_ENTER):
		_play("Run")
		_anim.speed_scale = clampf(_speed / NATURAL_SPEED, SCALE_MIN, SCALE_MAX)
	else:
		_play("Idle")


## ダイブ中は速度・接地に関係なくダイブ姿勢を優先する。
## 体の前傾そのものは親が Humanoid ごと rotation.x を倒して作る
func set_diving(value: bool) -> void:
	_diving = value


func _play(anim_name: String) -> void:
	if _state == anim_name:
		return
	_state = anim_name
	# speed_scale は AnimationPlayer 全体に効くので、Run 以外へ移る時に必ず戻す
	_anim.speed_scale = 1.0
	_anim.play(anim_name, BLEND)
