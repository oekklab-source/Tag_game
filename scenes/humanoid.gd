class_name Humanoid
extends Node3D

## Blender 製の Fall Guys 風ちびキャラ。プレイヤーと CPU で共用し、
## 移動速度・接地・ダイブ状態からアニメを切り替える。
##
## 見た目は3つを独立に組み合わせる:
##   - キャラ（SKINS）: Model を丸ごと差し替える。どのキャラも
##     tools/blender/character_common.py が同じリグと同じ名前のアニメクリップを
##     焼くので、ここは glb を入れ替えるだけでよく、アニメの分岐は一切要らない。
##   - コスチューム（CostumeCatalog）: 面ごとの塗り分け。面の構成が
##     CostumeCatalog.PART_SURFACES と一致するキャラ（きょうりゅう）にだけ効く。
##   - 帽子（HatCatalog）: Chest ボーンへの剛体アタッチ。リグが共通なのでどのキャラにも付く。
##
## 役割（Runner / Hunter）は**体色ではなく頭上の文字ラベル**で示す
## （player.gd の RoleLabel）。キャラごとに配色が違うので体色は使えないし、
## 装束を本物の服として塗れる方が着せ替えとして面白い。

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
## エモートは数秒間まわし続けるので、Idle/Run と同じくループ扱いにする
## （glTF 既定のワンショットのままだと1周で止まったポーズのまま固まる）
const LOOPING := ["Idle", "Run", "Jump", "Nice", "Come", "ComeHip", "ComeCool"]
## エモート ID（Player.Emote）と再生するクリップ名の対応。
## 2〜4 はラウンド中の挑発3種（前のめり / 腰ふり / 余裕）
const EMOTE_ANIM := {1: "Nice", 2: "Come", 3: "ComeHip", 4: "ComeCool"}

## 転倒中だけ頭の上でまわる星の輪。stunned で駆動するので、
## プレイヤーも CPU も、他ピアの画面でも同じように出る
const STAR_SPIN := 4.0        # まわる速さ rad/s
const STAR_UP := 0.26         # 頭のてっぺんからどれだけ浮かせるか
## Chest ボーンの原点から頭のてっぺんまでの距離（Blender のボーン長 0.56）。
## 顔面ダイブでは頭が前方 1m・高さ 0.5m まで動くので、頭の位置は
## ボーンから毎フレーム取り直すしかない。ボーンのローカル軸は Blender と glTF で
## 向きが変わるため、この値と向きは tests/slip.tscn が実測して確かめている
const HEAD_FROM_CHEST := 0.56

## 着せ替えのキャラ。ロビー（main.gd）で選び、ProfileManager.skin に保存され、
## GameManager のプロフィール同期（peer_profiles の "skin"）で全ピアに配られる。
## 並び順がそのまま保存値なので、**既存の項目の順番は変えないこと**
## （入れ替えると保存済みの設定が別のキャラになる）。
const SKINS := [
	{"name": "きょうりゅう", "path": "res://assets/character/fallguy.glb"},
	{"name": "しのび", "path": "res://assets/character/ninja.glb"},
]
## Blender では -Y を正面にモデリングしたが、glTF(+Y up) 変換でそれが +Z に来るため
## 180度回して Godot の正面（-Z）に合わせる（元は humanoid.tscn の Model にあった）
const MODEL_BASIS := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))

## コスチュームの塗り分け対象パーツ（CostumeCatalog.PART_SURFACES と対応）
const PARTS := ["Body", "Costume", "Face"]

var _diving := false
var _stunned := false
var _emote := 0
var _state := ""
var _speed := 0.0
var _star_angle := 0.0
var _skin := -1

var _model: Node3D
var _anim: AnimationPlayer
var _skel: Skeleton3D
var _chest := -1

var _mesh_nodes := {}       # "Body" -> MeshInstance3D
var _override_keys := []    # 直前に上書きした "Body:0" 等のキー（切替時のクリア用）
var _costume_id: StringName = CostumeCatalog.DEFAULT_ID
var _costume_colors := CostumeCatalog.default_colors(CostumeCatalog.DEFAULT_ID)

## 帽子（新規ジオメトリの部位）。apply_costume() が既存サーフェスの塗り分けだけを
## 扱うのに対し、こちらはメッシュそのものの追加/削除を扱う
var _hat_id: StringName = HatCatalog.DEFAULT_ID
var _hat_instance: Node3D = null
var _hat_attachment: BoneAttachment3D = null

@onready var _stars: Node3D = $Stars


func _ready() -> void:
	if _skin < 0:
		set_skin(0)


## 着せ替えを差し替える。生成前（_ready より先）に呼ばれることもあるので、
## _stars に依存せず単体で完結させる。
##
## 差し替えると AnimationPlayer ごと入れ替わるため、再生中のクリップは
## 状態(_state)を消してから同じものを鳴らし直す。そうしないと _play() が
## 「もう再生中」と判断して新しいモデルが Rest ポーズのまま固まる。
## コスチュームと帽子も古いモデルと一緒に消えるので、選択中のものを付け直す。
func set_skin(id: int) -> void:
	var index := id if id >= 0 and id < SKINS.size() else 0
	if index == _skin:
		return
	_skin = index
	var was := _state
	if _model:
		# queue_free() はフレーム末まで実行されない。木に残したまま同じ名前の
		# ノードを足すと Godot が新しい方を勝手に改名し、get_node("Model") が
		# 消える寸前の古いモデルを掴んでしまう。先に木から外すこと
		remove_child(_model)
		_model.queue_free()
	_model = (load(SKINS[index]["path"]) as PackedScene).instantiate()
	_model.name = "Model"
	_model.transform = Transform3D(MODEL_BASIS, Vector3.ZERO)
	add_child(_model)
	_anim = _model.find_child("AnimationPlayer", true, false)
	_skel = _model.find_child("Skeleton3D", true, false)
	_chest = _skel.find_bone("Chest")
	# glTF のアニメは既定でワンショット扱いなので、ループするものだけ設定し直す
	for anim_name in LOOPING:
		var anim := _anim.get_animation(anim_name)
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR

	_mesh_nodes.clear()
	_override_keys.clear()
	for part in PARTS:
		var node: MeshInstance3D = _model.find_child(part, true, false)
		if node:
			_mesh_nodes[part] = node
	# 帽子の装着点。このリグには首ボーンが無く Chest が頭を兼ねる
	_hat_instance = null
	_hat_attachment = BoneAttachment3D.new()
	_hat_attachment.name = "HatAttachment"
	_hat_attachment.bone_name = "Chest"
	_skel.add_child(_hat_attachment)
	apply_costume(_costume_id, _costume_colors)
	apply_hat(_hat_id)

	_state = ""
	_play(was if not was.is_empty() else "Idle")


## 星は頭に追従させるが、輪そのものは常に水平にまわす。
## Humanoid ごと傾く（ダイブ）ことも、うつ伏せで頭だけ前へ出ることもあるので、
## 親のローカル座標ではなく世界座標で置き直す
func _process(delta: float) -> void:
	_stars.visible = _stunned
	if not _stunned:
		return
	_star_angle = fmod(_star_angle + delta * STAR_SPIN, TAU)
	var head: Vector3 = _skel.global_transform * (_skel.get_bone_global_pose(_chest)
		* (Vector3.UP * HEAD_FROM_CHEST))
	_stars.global_position = head + Vector3.UP * STAR_UP
	_stars.global_basis = Basis(Vector3.UP, _star_angle)


## コスチューム（部位ごとの塗り分けレシピ）を適用する。
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
	# 選択は覚えておき、面の構成が違うキャラ（しのび）では塗らない。
	# レシピは面の添字で指定しているので、構成が違うと別の部位を塗ってしまう
	if not _fits_costume_parts():
		return

	var def: Dictionary = CostumeCatalog.get_def(_costume_id)
	for surf in def.get("surfaces", []):
		var part: String = surf["part"]
		var index: int = surf["index"]
		var node: MeshInstance3D = _mesh_nodes.get(part)
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


func _fits_costume_parts() -> bool:
	for part in PARTS:
		var node: MeshInstance3D = _mesh_nodes.get(part)
		if node == null or node.mesh == null \
				or node.mesh.get_surface_count() != CostumeCatalog.PART_SURFACES[part]:
			return false
	return true


## 頭部装備（新規ジオメトリ、スキニング無しの剛体アタッチ）を差し替える。
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


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す。
##
## speed は「実際の velocity（権威ピア）」か「同期値の変化から求めた推定（他ピア）」。
## 描画フレームごとの位置差分から出してはいけない。描画が物理より速いと
## 差分ゼロのフレームが混ざり、Idle と Run が交互に出てガタガタになる
func update_motion(speed: float, on_floor: bool, delta: float) -> void:
	_speed = lerpf(_speed, speed, 1.0 - exp(-delta * SPEED_SMOOTH))
	# 転倒は最優先。接地していて速度もほぼゼロなので、放っておくと Idle で棒立ちになる
	if _stunned:
		_play("Slip")
		return
	if _diving:
		_play("Dive")
		return
	# エモートのポーズは脚まで含めて全身を上書きするので、走りながら出すと
	# 脚が止まって見える。立ち止まっている時だけ再生し、走り出したら
	# 見た目は Run に戻す（吹き出しとマップの光は player.gd 側で出したままにする）
	if _emote != 0 and on_floor and _speed <= WALK_EXIT:
		_play(EMOTE_ANIM[_emote])
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


## バナナを踏んで転んでいる間。Slip（顔面ダイブ）は 1.5秒ワンショットで、
## banana.gd の STUN と同じ長さなので終わりがそのままスタン明けに一致する。
## 頭上の星もこのフラグで出す
func set_stunned(value: bool) -> void:
	_stunned = value


## Player.Emote の値。0 = 出していない。CPU は呼ばないので既定の 0 のまま
func set_emote(value: int) -> void:
	_emote = value if EMOTE_ANIM.has(value) else 0


func _play(anim_name: String) -> void:
	if _state == anim_name:
		return
	_state = anim_name
	# speed_scale は AnimationPlayer 全体に効くので、Run 以外へ移る時に必ず戻す
	_anim.speed_scale = 1.0
	_anim.play(anim_name, BLEND)
