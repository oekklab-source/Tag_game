shader_type spatial;

// ダッシュパネルの板（Plate）。glb に焼いた1枚のタイル絵を、山型が前へ流れるようにずらして描く。
// 絵は tools/blender/build_boost_panel.py の make_plate_texture() が作る。
// Blender 側のマテリアルを StandardMaterial3D のまま使わないのは、UV のスクロールと
// 光沢の帯を足したいため（どちらも標準マテリアルでは時刻を外から渡せない）。
//
// 時刻をシェーダの TIME でなく uniform で受けるのは、位相を GameManager.world_time に
// 揃えて全ピアで同じ絵にするため（ラウンド開始で全ピア同時にゼロへ戻る。
// beacon.gdshader の規約と同じく、当たり判定のあるギミックは TIME に頼らない）。
// boost_panel.gd が毎フレーム scroll と sheen を入れる。
//
// Web（Compatibility レンダラ）でも動くよう、サンプラ1つと数式だけの単純な内容に留める。
//
// unshaded にしてあるのは配色を守るため。ライティングありで ALBEDO と EMISSION の両方に
// 絵を入れると、ワールドの強い日差しと glow（glow_hdr_threshold = 1.0）で板全体が
// 白飛びし、ピンクも橙も薄い黄色に流れる（2026-10-04 に world.tscn 上で実測）。
// 絵の色をそのまま出せば Blender のプレビューと同じ色になり、どのゾーンに置いても変わらない。
// 影が落ちなくなるが、自分で光っている板として扱う
render_mode unshaded;

uniform sampler2D tile : source_color, repeat_enable, filter_linear_mipmap;
uniform float scroll = 0.0;   // 0..1。タイル1枚ぶんで1周
uniform float sheen = 0.0;    // 0..1。板の端から端で1周
uniform float tiles = 2.0;    // 板の縦に並ぶタイル枚数。build_boost_panel.py の V_TILES と揃える
uniform float energy = 1.0;       // 1.0 を超えると glow の閾値を越えて滲む
uniform float sheen_strength = 0.30;  // 帯の所だけ 1.0 を越えさせて、そこだけ滲ませる

void fragment() {
	// **向きの根拠。** glTF は V を上下反転して持ち込む（Godot の UV.y = 1 - Blender の v）ので、
	// UV.y に scroll を足すと絵は Blender の +v = +Y = Godot の -Z（パネルの前）へ流れる。
	// 符号を逆にすると山型が後ろへ流れる
	vec3 c = texture(tile, UV + vec2(0.0, scroll)).rgb;

	// 光沢の帯。p が 0.5 付近のときだけ細く立ち、板を横切って山型と同じ向きへ流れる。
	// UV.y は板の端から端で tiles ぶん動くので、tiles で割って 1 周にする
	float p = fract(UV.y / tiles + sheen);
	float band = smoothstep(0.42, 0.50, p) * (1.0 - smoothstep(0.50, 0.58, p));

	ALBEDO = c * energy + vec3(band * sheen_strength);
}
