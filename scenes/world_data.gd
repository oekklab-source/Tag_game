class_name WorldData
extends RefCounted

## マップ形状の唯一の定義。
## ゾーン判定（GameManager）・HUD のミニマップ・スポーン位置・ギミック配置が
## すべてここを参照するため、レイアウトを変える時はこのファイルだけを直せばよい。
##
## 全ピアが同じ形状を構築する必要があるため、値はすべて定数。
## 乱数を使うのは装飾配置のみで、固定シード（BUILD_SEED）から生成する。

const WORLD_HALF := 80.0   # x, z の範囲は [-80, +80]
const BAND := 27.0         # ゾーン境界。|x| または |z| がこれを超えると外側ゾーン
const SLAB_BOTTOM := -6.0  # 全ゾーンの床ブロックの底面
const WALL_HEIGHT := 20.0
const FALL_LIMIT := -20.0  # これより下に落ちたら中央へ復帰させる
const BUILD_SEED := 20260728

## 3x3 グリッド。index = col + row * 3
## col: 0=西(x<-27) / 1=中央 / 2=東(x>27)　row: 0=北(z<-27) / 1=中央 / 2=南(z>27)
const ZONE_COUNT := 9
const ZONE_COL: Array[int] = [0, 1, 2, 0, 1, 2, 0, 1, 2]
const ZONE_ROW: Array[int] = [0, 0, 0, 1, 1, 1, 2, 2, 2]

const AXIS_CENTER: Array[float] = [-53.5, 0.0, 53.5]
const AXIS_SIZE: Array[float] = [53.0, 54.0, 53.0]

const ZONE_NAMES: Array[String] = [
	"CLOUD DECK", "PIPE YARD", "BLOCK PLAZA",
	"GARDEN GREEN", "CASTLE COURT", "BOOST CIRCUIT",
	"SPRING VALLEY", "LIFT HARBOR", "SKY STEPS",
]

## 各ゾーンの地面の高さ。段丘状に高低差をつけ、隣接ゾーン間はスロープで繋ぐ
const ZONE_GROUND: Array[float] = [8.0, 2.0, 4.0, 1.0, 0.0, 1.0, 3.0, 0.0, 6.0]

## 床の基調色。HUD のラベル色とミニマップ色はここから導出する
const ZONE_COLORS: Array[Color] = [
	Color(0.50, 0.80, 1.00),  # CLOUD DECK    水色
	Color(0.18, 0.72, 0.30),  # PIPE YARD     緑
	Color(0.95, 0.48, 0.10),  # BLOCK PLAZA   橙
	Color(0.48, 0.80, 0.20),  # GARDEN GREEN  黄緑
	Color(0.82, 0.24, 0.24),  # CASTLE COURT  赤
	Color(0.52, 0.30, 0.92),  # BOOST CIRCUIT 紫
	Color(0.96, 0.76, 0.12),  # SPRING VALLEY 黄
	Color(0.18, 0.48, 0.92),  # LIFT HARBOR   青
	Color(0.96, 0.38, 0.64),  # SKY STEPS     桃
]

## 隣接ゾーンのペア。前が西/北側、後ろが東/南側。スロープはこの順で生成する
const RAMP_PAIRS_X: Array = [[0, 1], [1, 2], [3, 4], [4, 5], [6, 7], [7, 8]]
const RAMP_PAIRS_Z: Array = [[0, 3], [3, 6], [1, 4], [4, 7], [2, 5], [5, 8]]

## 滑り台。降りるのは速いが登れない一方通行の近道。
## ジャンプ台が「登り」なので、滑り台は同じゾーン対の「下り」として対をなし、
## 高所2ゾーン（CLOUD DECK 8m / SKY STEPS 6m）が登って滑り降りる拠点になる。
##
## [高いゾーン, 低いゾーン, 境界に沿った横オフセット]
## 走路長は落差から自動算出する（スロープより急な SLIDE_RUN_PER_RISE）。
## 走路は直線・一定傾斜。曲げるとセグメントの継ぎ目で足が引っかかる。
##
## 滑り台を架けた境界からはスロープを撤去し（_build_ramps）、
## 落差のある縁には柵を立てる（_build_parapets）。
## そうしないと「歩いて降りる」「飛び降りる」で代替できてしまい滑り台の意味がなくなる。
## 代わりに CPU 用の一方通行ナビリンクを張る（_build_nav_links）
const SLIDES: Array = [
	[0, 3, -16.5],   # CLOUD DECK 8m -> GARDEN GREEN  1m（登りは SPRING_PADS[1]）
	[0, 1, 16.5],    # CLOUD DECK 8m -> PIPE YARD     2m（登りは SPRING_PADS[0]）
	[8, 7, 16.5],    # SKY STEPS  6m -> LIFT HARBOR   0m（登りは SPRING_PADS[2]）
	[8, 5, -16.5],   # SKY STEPS  6m -> BOOST CIRCUIT 1m（出口がダッシュパネル周回コース）
]

## --- ギミック配置 ------------------------------------------------------
## いずれも [ゾーン番号, ローカルX, ローカルZ, (ヨー角°)]。
## 座標はゾーン中心からの相対で、Y はそのゾーンの地面高さになる。

## ジャンプ台。高いゾーン（CLOUD DECK / SKY STEPS）への登坂ルートを兼ねる。
## [ゾーン, ローカルX, ローカルZ, 登る先のゾーン（無ければ -1）]
##
## 登る先を明記するのは、そのゾーンの柵（_build_parapets）に着地用の口を
## 空けるため。塞ぐと打ち上げの頂点が柵に阻まれ、登坂ルートが消えてしまう
## （GARDEN GREEN からの頂点は CLOUD DECK の床の 1.6m 上しかない）
const SPRING_PADS: Array = [
	[1, -19.0, 0.0, 0],    # PIPE YARD     -> CLOUD DECK
	[3, 0.0, -19.0, 0],    # GARDEN GREEN  -> CLOUD DECK
	[7, 19.0, 0.0, 8],     # LIFT HARBOR   -> SKY STEPS
	[5, 0.0, 19.0, 8],     # BOOST CIRCUIT -> SKY STEPS
	[6, -12.0, -12.0, -1],  # SPRING VALLEY
	[6, 12.0, -12.0, -1],
	[6, 0.0, 14.0, -1],
	[4, 0.0, -20.0, -1],   # CASTLE COURT  -> PIPE YARD（落差2mなので柵は無い）
]

## ダッシュパネル。BOOST CIRCUIT の周回コース4枚 + 各所に4枚
const BOOST_PANELS: Array = [
	[5, 0.0, -16.0, -90.0],
	[5, 16.0, 0.0, 180.0],
	[5, 0.0, 16.0, 90.0],
	[5, -16.0, 0.0, 0.0],
	[4, 20.0, 0.0, -90.0],
	[2, 0.0, 16.0, 180.0],
	[3, 16.0, 0.0, -90.0],
	[7, -18.0, 0.0, 90.0],
]

## 土管。2本ずつペアになる（0-1 と 2-3）。高低差の大きいゾーンを直結する近道
const WARP_PIPES: Array = [
	[1, 14.0, 0.0],     # PIPE YARD    <-> SKY STEPS
	[8, -14.0, 0.0],
	[4, -20.0, 0.0],    # CASTLE COURT <-> CLOUD DECK
	[0, 14.0, 0.0],
]

## ？ブロック。BLOCK PLAZA と GARDEN GREEN に密集させ、残りを各ゾーンへ散らす
const QUESTION_BLOCKS: Array = [
	[2, -8.0, -8.0], [2, 8.0, -8.0], [2, -8.0, 8.0], [2, 8.0, 8.0],
	[3, 0.0, -11.0], [3, -11.0, 7.0], [3, 11.0, 7.0],
	[1, 8.0, 10.0],
	[4, -12.0, 12.0], [4, 12.0, 12.0],
	[5, -14.0, -14.0],
	[6, 14.0, 8.0],
	[7, -10.0, -11.0],
	[8, 10.0, 10.0],
]

## 動く床。[ゾーン, ローカルX, 高さ, ローカルZ, 移動X, 移動Y, 移動Z, 周期秒]
## LIFT HARBOR の昇降2基 + 上空シャトル2基、CLOUD DECK の周遊シャトル2基
const MOVING_PLATFORMS: Array = [
	[7, -14.0, 0.0, 0.0, 0.0, 7.0, 0.0, 8.0],
	[7, 14.0, 0.0, 0.0, 0.0, 7.0, 0.0, 8.0],
	[7, -14.0, 7.0, 5.0, 28.0, 0.0, 0.0, 9.0],
	[7, 14.0, 7.0, -5.0, -28.0, 0.0, 0.0, 9.0],
	# CLOUD DECK の周遊シャトルは地上高。以前は +4m にあり、
	# ジャンプ(1.38m)でもスロープでも乗れない孤立した足場になっていた
	[0, -12.0, 0.0, -12.0, 0.0, 0.0, 24.0, 10.0],
	[0, 12.0, 0.0, 12.0, 0.0, 0.0, -24.0, 10.0],
]

## 回転床。[ゾーン, ローカルX, 高さ, ローカルZ, 角速度 rad/s]
const ROTATING_PLATFORMS: Array = [
	[3, -14.0, 1.2, -14.0, 0.6],
	[3, 14.0, 1.2, -14.0, -0.6],
	[3, -14.0, 1.2, 14.0, -0.6],
	[3, 14.0, 1.2, 14.0, 0.6],
]


## --- ゾーンのテーマ -----------------------------------------------------
## 「何を置くか」だけをここで決める。「どこに置くか」は world_builder の
## 象限ループが決め、十字通路・スポーン地・隙間といった不変条件も配置側が担保する。
## だからここを編集してもレイアウトの安全性は壊れない。

## 視線を切る構造物。
## 地面から6m以上まで途切れずに塞ぐ形だけを並べること。視線レイは y=0.85 と y=1.55 で、
## 6m はカメラ（SpringArm の最大高 約3.6m）からも見えなくなる高さ。
## 宙に浮いた傘や細すぎる柱を混ぜると「画面では壁越しに見えているのに
## can_see は false」になって破綻する
enum Prop { WALL, TOWER, PIPE, CRATE }

## ゾーンごとの [プロップ, 重み]。重みは相対値なので合計は揃えなくてよい
const ZONE_THEMES: Array = [
	[[Prop.TOWER, 3], [Prop.PIPE, 1]],   # 0 CLOUD DECK    雲を突く柱
	[[Prop.PIPE, 4], [Prop.CRATE, 1]],   # 1 PIPE YARD     配管ヤード
	[[Prop.CRATE, 3], [Prop.WALL, 2]],   # 2 BLOCK PLAZA   積み木の広場
	[[Prop.TOWER, 2], [Prop.WALL, 2]],   # 3 GARDEN GREEN  庭園
	[[Prop.WALL, 3], [Prop.TOWER, 2]],   # 4 CASTLE COURT  城壁と塔
	[[Prop.PIPE, 3], [Prop.WALL, 1]],    # 5 BOOST CIRCUIT ネオンのゲート柱
	[[Prop.TOWER, 3], [Prop.CRATE, 1]],  # 6 SPRING VALLEY
	[[Prop.CRATE, 4], [Prop.PIPE, 1]],   # 7 LIFT HARBOR   港のコンテナ
	[[Prop.TOWER, 2], [Prop.PIPE, 2]],   # 8 SKY STEPS
]

## ゾーンの目印。1ゾーン1個だけ手で置く。ここだけ座標を指定する。
## [ゾーン, ローカルX, ローカルZ, プロップ, 大きさ倍率]
## 制約: 中心からの距離が SPAWN_CLEARANCE(10) より遠く、十字通路(±9)の外にあること
const ZONE_LANDMARKS: Array = [
	[0, -19.0, -19.0, Prop.TOWER, 2.1],
	[1, 17.0, 15.0, Prop.PIPE, 2.2],
	[2, 18.0, -17.0, Prop.CRATE, 1.9],
	[3, -18.0, 16.0, Prop.TOWER, 1.8],
	[4, 19.0, 19.0, Prop.TOWER, 2.3],
	[5, -17.0, -18.0, Prop.PIPE, 2.0],
	[6, -18.0, 17.0, Prop.TOWER, 1.9],
	[7, 16.0, -18.0, Prop.CRATE, 2.1],
	[8, 17.0, 17.0, Prop.TOWER, 2.0],
]

## 構造物のアクセント色。床（ZONE_COLORS）と分離して見えるよう、
## 同系色ではなく一段濃い/ずらした色にする
const ZONE_ACCENTS: Array[Color] = [
	Color(0.72, 0.84, 1.00),  # 0 CLOUD DECK    青みの白（雲）
	Color(0.16, 0.52, 0.42),  # 1 PIPE YARD     深緑
	Color(0.80, 0.28, 0.24),  # 2 BLOCK PLAZA   レンガ
	Color(0.30, 0.55, 0.28),  # 3 GARDEN GREEN  葉の緑
	Color(0.74, 0.66, 0.52),  # 4 CASTLE COURT  石灰
	Color(0.55, 0.24, 0.94),  # 5 BOOST CIRCUIT ネオン紫
	Color(0.96, 0.48, 0.20),  # 6 SPRING VALLEY 橙
	Color(0.18, 0.34, 0.60),  # 7 LIFT HARBOR   紺
	Color(0.95, 0.42, 0.70),  # 8 SKY STEPS     桃
]


static func zone_accent(idx: int) -> Color:
	return ZONE_ACCENTS[idx]


static func zone_index(pos: Vector3) -> int:
	var col := 0 if pos.x < -BAND else (2 if pos.x > BAND else 1)
	var row := 0 if pos.z < -BAND else (2 if pos.z > BAND else 1)
	return col + row * 3


## ゾーン中心のワールド座標（y はそのゾーンの地面の高さ）
static func zone_center(idx: int) -> Vector3:
	return Vector3(AXIS_CENTER[ZONE_COL[idx]], ZONE_GROUND[idx], AXIS_CENTER[ZONE_ROW[idx]])


## ゾーン中心からのローカル座標をワールド座標へ（Y はそのゾーンの地面高さ）
static func zone_point(idx: int, dx: float, dz: float) -> Vector3:
	var c := zone_center(idx)
	return Vector3(c.x + dx, c.y, c.z + dz)


static func zone_name(idx: int) -> String:
	return ZONE_NAMES[idx]


static func zone_color(idx: int) -> Color:
	return ZONE_COLORS[idx]


## ゾーンの床の平面サイズ（x, z）
static func zone_extent(idx: int) -> Vector2:
	return Vector2(AXIS_SIZE[ZONE_COL[idx]], AXIS_SIZE[ZONE_ROW[idx]])
