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

## --- ギミック配置 ------------------------------------------------------
## いずれも [ゾーン番号, ローカルX, ローカルZ, (ヨー角°)]。
## 座標はゾーン中心からの相対で、Y はそのゾーンの地面高さになる。

## ジャンプ台。高いゾーン（CLOUD DECK / SKY STEPS）への登坂ルートを兼ねる
const SPRING_PADS: Array = [
	[1, -19.0, 0.0],    # PIPE YARD     -> CLOUD DECK
	[3, 0.0, -19.0],    # GARDEN GREEN  -> CLOUD DECK
	[7, 19.0, 0.0],     # LIFT HARBOR   -> SKY STEPS
	[5, 0.0, 19.0],     # BOOST CIRCUIT -> SKY STEPS
	[6, -12.0, -12.0],  # SPRING VALLEY
	[6, 12.0, -12.0],
	[6, 0.0, 14.0],
	[4, 0.0, -20.0],    # CASTLE COURT  -> PIPE YARD
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
