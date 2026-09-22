/**
 * rating_model.ts の検証テスト。
 *
 * 実行方法: npm test (= tsx --test src/rating_model.test.ts)
 *
 * 構成:
 *   1) tests/rating_model.gd の9ケースをそのまま移植(数式の性質: ゼロサム性・単調性・
 *      ボーナスカーブ・ティア整合・トドメ再分配・逃げ切り対称性)
 *   2) docs/RATING_SYSTEM.md §3 の数値表をゴールデン値として直接assertするケース
 *      (仕様書・GDScript・TSの3点が常に一致していることを機械的に保証する)
 *   3) GDScriptの round() (0から遠い方向)とJSの Math.round() (+∞方向)の
 *      丸め方式の差異を明示的にテストするケース(負の.5境界)
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import {
	BONUS_FULL_BELOW,
	BONUS_ZERO_AT,
	MAX_TIME,
	bonusWeight,
	calculateAllRatingChanges,
	calculateRatingDelta,
	roundHalfAwayFromZero,
	tierId,
} from "./rating_model.js";

function isCloseTo(actual: number, expected: number, tolerance = 0.001): void {
	assert.ok(
		Math.abs(actual - expected) < tolerance,
		`expected ${actual} to be within ${tolerance} of ${expected}`,
	);
}

function sum(values: number[]): number {
	return values.reduce((a, b) => a + b, 0);
}

// --- [1] 要件シミュレーション例の検証 (1500 vs 1500 x 4) ---
test("standard cases: capture and clean escape are zero-sum", () => {
	const rRatings = [1500, 1500, 1500, 1500];

	const res1 = calculateAllRatingChanges(1500, rRatings, 120.0, 0, false);
	assert.ok(res1.runnerDelta < 0.0);
	assert.ok(res1.hunterDeltas[0] > res1.hunterDeltas[1]);
	isCloseTo(res1.runnerDelta + sum(res1.hunterDeltas), 0.0);

	const res2 = calculateAllRatingChanges(1500, rRatings, 180.0, -1, false);
	assert.ok(res2.runnerDelta > 0.0);
	assert.ok(res2.hunterDeltas[0] < 0.0);
	isCloseTo(res2.runnerDelta + sum(res2.hunterDeltas), 0.0);
});

// --- [2] 多様な人数・レート格差での Zero-Sum 特性検証 ---
test("zero-sum property holds across hunter counts, ratings, and survival times", () => {
	const counts = [1, 3, 5, 7];
	for (const n of counts) {
		const hRatings: number[] = [];
		for (let i = 0; i < n; i++) {
			hRatings.push(1200.0 + i * 150.0);
		}
		const runnerR = 1600.0;
		for (const t of [30.0, 90.0, 150.0, 180.0]) {
			const toucher = t < 180.0 ? 0 : -1;
			const res = calculateAllRatingChanges(runnerR, hRatings, t, toucher, false);
			const net = res.runnerDelta + sum(res.hunterDeltas);
			isCloseTo(net, 0.0);
		}
	}
});

// --- [3] 生存時間に対する単調性 (Runnerは長く生きるほど得をする) ---
test("runner delta is monotonically non-decreasing with survival time", () => {
	let prevRunnerDelta = -999.0;
	const hRatings = [1500, 1500, 1500];
	for (const sec of [0.0, 30.0, 60.0, 90.0, 120.0, 150.0, 179.9, 180.0]) {
		const res = calculateAllRatingChanges(1500, hRatings, sec, 0);
		assert.ok(res.runnerDelta >= prevRunnerDelta);
		prevRunnerDelta = res.runnerDelta;
	}
});

// --- [4] 低レート帯ボーナス係数のカーブ検証 ---
test("bonus_weight curve: 1.0 below 1400, 0.0 at/above 1800, linear between", () => {
	const samples = [1000, 1200, 1400, 1600, 1800, 2000];
	let prevW = 2.0;
	for (const r of samples) {
		const w = bonusWeight(r);
		assert.ok(w <= prevW);
		prevW = w;
	}
	isCloseTo(bonusWeight(1200), 1.0, 1e-9);
	isCloseTo(bonusWeight(1400), 1.0, 1e-9);
	isCloseTo(bonusWeight(1600), 0.5, 1e-9);
	isCloseTo(bonusWeight(1800), 0.0, 1e-9);
	isCloseTo(bonusWeight(2000), 0.0, 1e-9);
});

// --- [5] 序盤レート帯 (全員1300) は純増になることの検証 ---
test("low rating tier nets a positive gain across both sides", () => {
	const hRatings = [1300, 1300, 1300, 1300];
	const res = calculateAllRatingChanges(1300, hRatings, 120.0, 0, true);
	const net = res.runnerDelta + sum(res.hunterDeltas);
	assert.ok(net > 0.0);
});

// --- [6] 上位レート帯 (全員2000) は従来通り完全ゼロサムのままであることの検証 ---
test("high rating tier stays exactly zero-sum (no bonus)", () => {
	const hRatings = [2000, 2000, 2000, 2000];
	const res = calculateAllRatingChanges(2000, hRatings, 120.0, 0, true);
	const net = res.runnerDelta + sum(res.hunterDeltas);
	isCloseTo(net, 0.0);
	isCloseTo(res.bonusTotal, 0.0, 1e-9);
});

// --- [7] レート帯(ティア)境界とボーナスしきい値の整合性検証 ---
test("tier boundaries match bonus thresholds (1400 / 1800)", () => {
	assert.equal(tierId(1399), "silver");
	assert.equal(tierId(1400), "gold");
	assert.equal(BONUS_FULL_BELOW, 1400);
	assert.equal(tierId(1799), "platinum");
	assert.equal(tierId(1800), "diamond");
	assert.equal(BONUS_ZERO_AT, 1800);
});

// --- [8] トドメ再分配が全クライアント独立計算でもゼロサムを保つことの検証 ---
test("touch-transfer stays zero-sum when computed independently per client", () => {
	const myRating = 2000;
	const hunterCount = 4;
	const survival = 90.0;

	const runnerDelta = calculateRatingDelta(true, false, survival, hunterCount, false, myRating, myRating);
	const taggerDelta = calculateRatingDelta(false, true, survival, hunterCount, true, myRating, myRating);
	let cooperatorsDelta = 0;
	for (let i = 0; i < hunterCount - 1; i++) {
		cooperatorsDelta += calculateRatingDelta(false, true, survival, hunterCount, false, myRating, myRating);
	}

	const net = runnerDelta + taggerDelta + cooperatorsDelta;
	assert.ok(Math.abs(net) <= 3); // 各クライアントで round するため丸め誤差ぶんのみ許容
});

// --- [9] 完全な逃げ切りでRunner視点とHunter視点のスコアが食い違わないことの検証 ---
test("clean escape scores agree between runner and hunter clients", () => {
	const runnerRating = 2000;
	const hunterRating = 2000;
	const hunterCount = 3;

	const runnerDelta = calculateRatingDelta(true, true, MAX_TIME, hunterCount, false, runnerRating, hunterRating);
	const hunterDelta = calculateRatingDelta(false, false, MAX_TIME, hunterCount, false, hunterRating, runnerRating);

	const hunterRatings = new Array(hunterCount).fill(hunterRating);
	const res = calculateAllRatingChanges(runnerRating, hunterRatings, MAX_TIME, -1);
	const expectedHunterDelta = roundHalfAwayFromZero(res.hunterDeltas[0]);

	assert.equal(hunterDelta, expectedHunterDelta);
	assert.ok(hunterDelta < -3);
	void runnerDelta; // GDScript版と同様、ここでは比較に使わない(参照用に計算のみ)
});

// --- docs/RATING_SYSTEM.md §3 のゴールデン値(apply_bonus=false、N=4、Runner/Hunter全員1500) ---
test("golden values: docs/RATING_SYSTEM.md §3 base scenario table", () => {
	const hRatings = [1500, 1500, 1500, 1500];

	// ① 2分捕獲(120秒)
	const r1 = calculateAllRatingChanges(1500, hRatings, 120.0, 0, false);
	isCloseTo(r1.runnerDelta, -5.33, 0.01);
	isCloseTo(r1.hunterDeltas[0], 2.53, 0.01);
	isCloseTo(r1.hunterDeltas[1], 0.93, 0.01);
	isCloseTo(r1.hunterDeltas[2], 0.93, 0.01);
	isCloseTo(r1.hunterDeltas[3], 0.93, 0.01);

	// ② 3分逃げ切り(180秒)
	const r2 = calculateAllRatingChanges(1500, hRatings, 180.0, -1, false);
	isCloseTo(r2.runnerDelta, 16.0, 0.01);
	for (const d of r2.hunterDeltas) {
		isCloseTo(d, -4.0, 0.01);
	}

	// ③ 秒殺(早期捕獲、15秒)
	const r3 = calculateAllRatingChanges(1500, hRatings, 15.0, 0, false);
	isCloseTo(r3.runnerDelta, -14.67, 0.01);
	isCloseTo(r3.hunterDeltas[0], 6.97, 0.01);
	isCloseTo(r3.hunterDeltas[1], 2.57, 0.01);

	// ④ 終了直前捕獲(175秒)
	const r4 = calculateAllRatingChanges(1500, hRatings, 175.0, 0, false);
	isCloseTo(r4.runnerDelta, -0.44, 0.01);
	isCloseTo(r4.hunterDeltas[0], 0.21, 0.01);
	isCloseTo(r4.hunterDeltas[1], 0.08, 0.01);
});

// --- docs/RATING_SYSTEM.md §3 のゴールデン値(低レート帯ボーナスの効果、apply_bonus=true、2分捕獲・N=4) ---
// 注: この表は元々docs側に計算誤りがあり、実際に res://tests/_tmp_verify_bonus.tscn で
// autoload/ranking_manager.gd を直接headless実行して数値を検証した上で、
// docs/RATING_SYSTEM.md §3 側を実装に合わせて修正した(2026-09-22、一時検証ファイルは削除済み)。
test("golden values: docs/RATING_SYSTEM.md §3 low-rating bonus table", () => {
	const cases: Array<{ rating: number; runnerDelta: number; net: number }> = [
		{ rating: 1300, runnerDelta: 2.67, net: 15.0 },
		{ rating: 1500, runnerDelta: 0.67, net: 11.25 },
		{ rating: 1700, runnerDelta: -3.33, net: 3.75 },
		{ rating: 2000, runnerDelta: -5.33, net: 0.0 },
	];
	for (const c of cases) {
		const hRatings = new Array(4).fill(c.rating);
		const res = calculateAllRatingChanges(c.rating, hRatings, 120.0, 0, true);
		isCloseTo(res.runnerDelta, c.runnerDelta, 0.01);
		isCloseTo(res.runnerDelta + sum(res.hunterDeltas), c.net, 0.01);
	}
});

// --- 丸め方式の差異(GDScriptのround()は0から遠い方向、JSのMath.round()は+∞方向) ---
test("rounding: roundHalfAwayFromZero matches GDScript round(), not native Math.round()", () => {
	// GDScriptのround(): round(2.5)==3.0, round(-2.5)==-3.0 (0から遠い方向)
	assert.equal(roundHalfAwayFromZero(2.5), 3);
	assert.equal(roundHalfAwayFromZero(-2.5), -3);
	assert.equal(roundHalfAwayFromZero(0.5), 1);
	assert.equal(roundHalfAwayFromZero(-0.5), -1);
	assert.equal(roundHalfAwayFromZero(0), 0);

	// JS組み込みのMath.round()は+∞方向に丸めるため、負の.5境界でGDScriptと食い違う。
	// この食い違いこそがroundHalfAwayFromZero()を用意した理由であることを明示しておく。
	assert.equal(Math.round(-2.5), -2);
	assert.notEqual(Math.round(-2.5), roundHalfAwayFromZero(-2.5));
});
