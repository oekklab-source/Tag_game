shader_type canvas_item;

// メニュー画面の背景。上から下へ濃くなる地の色に、斜めの縞がゆっくり流れる。
// 画像を使わないのは、Web 版のダウンロード容量を増やさず、どの縦横比でも継ぎ目が出ないため。

uniform vec4 top_color : source_color = vec4(0.58, 0.38, 1.0, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.33, 0.17, 0.80, 1.0);
// 縞の明るさ（地の色に白を混ぜる割合）
uniform float stripe_strength : hint_range(0.0, 0.5) = 0.07;
uniform float stripe_px = 150.0;
uniform float speed = 14.0;

void fragment() {
	// 縞は UV ではなく画面のピクセルで測る。UV だと画面の縦横比で縞の角度と太さが変わる
	float t = (FRAGCOORD.x + FRAGCOORD.y + TIME * speed) / stripe_px;
	float band = smoothstep(0.47, 0.53, abs(fract(t) - 0.5) * 2.0);
	vec4 base = mix(top_color, bottom_color, UV.y);
	COLOR = vec4(mix(base.rgb, vec3(1.0), band * stripe_strength), 1.0);
}
