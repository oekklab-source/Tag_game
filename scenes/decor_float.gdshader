shader_type spatial;

// 装飾の「ふわふわ」を頂点シェーダで作る。
//
// 規約: 当たり判定のある物は GameManager.world_time（全ピアで揃える必要がある）、
// 装飾だけの物はこのシェーダの TIME。装飾は当たらないので同期が要らず、
// MultiMesh 数百個の transform を毎フレーム CPU で書き換えずに済む。
//
// world_vertex_coords を使うのは、VERTEX をワールド座標で扱うため。
// モデル空間のままだとインスタンスの拡大率がそのまま揺れ幅に掛かり、
// 大きい雲ほど大きく揺れてバラバラに見える。ワールド空間なら揺れ幅がメートルで一定。
render_mode world_vertex_coords, cull_back;

uniform vec3 albedo : source_color = vec3(1.0);
uniform float emission_energy = 0.3;
uniform float sway = 0.0;   // 水平の揺れ幅(m)
uniform float bob = 0.0;    // 上下の揺れ幅(m)
uniform float spin = 0.0;   // 自転(rad/s)
uniform float speed = 1.0;  // 揺れの速さ

void vertex() {
	// インスタンスごとの位相。1つの雲を作る3つの球には同じ値を入れてあるので、
	// 塊としてまとまったまま動く（バラけると雲に見えなくなる）
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float t = TIME * speed + phase;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 p = VERTEX - origin;
	if (spin != 0.0) {
		float a = TIME * spin + phase;
		float s = sin(a);
		float c = cos(a);
		p = vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
		NORMAL = vec3(NORMAL.x * c - NORMAL.z * s, NORMAL.y, NORMAL.x * s + NORMAL.z * c);
	}
	VERTEX = origin + p
		+ vec3(sin(t) * sway, sin(t * 1.3) * bob, cos(t * 0.8) * sway);
}

void fragment() {
	ALBEDO = albedo;
	EMISSION = albedo * emission_energy;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
