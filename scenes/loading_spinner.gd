extends Control

## L-06: 汎用ローディングスピナー。_draw()+Timerのみで完結させ、
## RenderingServer.frame_post_draw等のフレーム完了待ちには一切依存しない
## (CLAUDE.mdの「テストの流し方」節にある通り、headlessでは永久に発火せずハングする原因になるため)。

const POINT_COUNT := 8
const MIN_ALPHA := 0.15

@export var dot_color: Color = Color(0.35, 0.8, 1.0)
@export var dot_radius: float = 3.0

@onready var _timer: Timer = $Timer

var _tick := 0


func _ready() -> void:
	_timer.timeout.connect(_on_timer_timeout)
	visible = false


## 冪等: 既にactive/inactiveな状態で呼んでも安全。呼び出し側は
## 「待機の開始/終了」のたびに気軽にtrue/falseを渡せばよい
func set_active(active: bool) -> void:
	if active:
		visible = true
		_tick = 0
		queue_redraw()
		_timer.start()
	else:
		_timer.stop()
		visible = false


func _on_timer_timeout() -> void:
	_tick = (_tick + 1) % POINT_COUNT
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var r := minf(center.x, center.y) - dot_radius - 1.0
	if r <= 0.0:
		return
	for i in POINT_COUNT:
		var angle := TAU * i / POINT_COUNT - PI * 0.5
		var pos := center + Vector2(cos(angle), sin(angle)) * r
		var behind := posmod(_tick - i, POINT_COUNT)
		var alpha := lerpf(1.0, MIN_ALPHA, float(behind) / float(POINT_COUNT - 1))
		var col := dot_color
		col.a = alpha
		draw_circle(pos, dot_radius, col)
