shader_type spatial;

// マンホールの「神々しい目印」を作る加算合成シェーダ。
// 光柱（Beacon）と舞う結晶（Shards）で共用し、uniform で振る舞いを変える。
//
// 規約: 当たり判定のある物は GameManager.world_time（全ピアで揃える必要がある）、
// 装飾だけの物はこのシェーダの TIME。目印は当たらないので同期が要らない
// （decor_float.gdshader と同じ）。
//
// depth_draw_never が要点。加算合成でも深度を書くと、光柱の向こう側にいる
// キャラや地形が「光柱に隠されて消える」。書かなければ光として重なるだけになる。
// cull_disabled は、光柱が上下フタの無い開いた筒で内側も見えるため。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 albedo : source_color = vec3(0.62, 0.92, 1.0);
uniform float energy = 1.0;       // 1.0 前後。上げると加算が飽和して真っ白に潰れる
uniform float fade_height = 0.0;  // >0 でこの高さに向かって薄れる（光柱用・メートル）
uniform float bob = 0.0;          // 上下の揺れ幅(m)
uniform float stripe = 0.0;       // 上へ流れる縞の強さ

// フラグメントの VERTEX はビュー空間なので、モデル空間の高さは自前で運ぶ
varying float local_y;

void vertex() {
	local_y = VERTEX.y;
	if (bob > 0.0) {
		// 結晶は MultiMesh ではなく1メッシュに結合されているので INSTANCE_CUSTOM が使えない。
		// 1つの結晶の頂点はほぼ同じ方位角に集まるので、方位角を位相に使うと
		// 結晶ごとにばらけて揺れる（build_manhole.py は黄金角で並べてある）
		float phase = atan(VERTEX.x, VERTEX.z);
		VERTEX.y += sin(TIME * 1.7 + phase * 3.0) * bob;
	}
}

void fragment() {
	float k = 1.0;
	if (fade_height > 0.0) {
		float t = clamp(local_y / fade_height, 0.0, 1.0);
		// 上へ線形に薄れて空に溶ける。二次だと中腹から先が消えてしまい、
		// 遠景で「地面の光る点」にしか見えなくなる（実測）。
		// 根元は 1.5m ほどかけて立ち上げる。ここを抜かないと加算が飽和して
		// フタの意匠が真っ白に飛ぶ
		k = (1.0 - t) * smoothstep(0.0, 0.11, t);
	}
	float pulse = 0.72 + 0.28 * sin(TIME * 1.6);
	if (stripe > 0.0) {
		pulse += stripe * (0.5 + 0.5 * sin(local_y * 1.1 - TIME * 2.6));
	}
	ALBEDO = albedo * energy;
	ALPHA = clamp(k * pulse, 0.0, 1.0);
}
