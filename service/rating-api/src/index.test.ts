/**
 * index.ts のうち、D1/Workers runtimeを起動せずに検証できる純粋関数(バリデーション・
 * レート制限キー生成)の単体テスト。HTTPエンドポイント自体(D1に依存する部分)は
 * README.md記載の wrangler dev --local + curl による手動スモークテストで検証する
 * (service/friend-api・service/commerce-api にもエンドポイントレベルの自動テストの
 * 前例が無いため、この範囲を超える新規テストインフラ(vitest等)は導入しない)。
 *
 * 実行方法: npm test (= tsx --test src/rating_model.test.ts src/index.test.ts)
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import {
	claimRateLimitKey,
	clampLeaderboardLimit,
	isValidHunterPuids,
	isValidMatchId,
	leaderboardRateLimitKey,
	ratingQueryRateLimitKey,
	reportMatchRateLimitKey,
} from "./index.js";

test("isValidMatchId: 8〜128文字の英数字・アンダースコア・ハイフンのみ許可", () => {
	assert.equal(isValidMatchId("test-match-0001"), true);
	assert.equal(isValidMatchId("a".repeat(128)), true);
	assert.equal(isValidMatchId("short"), false); // 8文字未満
	assert.equal(isValidMatchId("a".repeat(129)), false); // 129文字
	assert.equal(isValidMatchId("has space"), false);
	assert.equal(isValidMatchId("has/slash1"), false);
	assert.equal(isValidMatchId(123), false);
	assert.equal(isValidMatchId(null), false);
});

test("isValidHunterPuids: 1〜7人、runner_puidとの重複・hunter内重複を拒否", () => {
	assert.equal(isValidHunterPuids("runner", ["h1", "h2"]), true);
	assert.equal(isValidHunterPuids("runner", ["h1", "h2", "h3", "h4", "h5", "h6", "h7"]), true); // 上限7人
	assert.equal(isValidHunterPuids("runner", []), false); // 0人
	assert.equal(
		isValidHunterPuids("runner", ["h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8"]),
		false,
	); // 8人(上限超過)
	assert.equal(isValidHunterPuids("runner", ["runner", "h2"]), false); // runnerと重複
	assert.equal(isValidHunterPuids("runner", ["h1", "h1"]), false); // hunter内重複
	assert.equal(isValidHunterPuids("runner", ["h1", ""]), false); // 空文字
	assert.equal(isValidHunterPuids("runner", "not-an-array"), false);
	assert.equal(isValidHunterPuids("runner", null), false);
});

test("clampLeaderboardLimit: 省略時は20、範囲外は[1,100]にクランプ", () => {
	assert.equal(clampLeaderboardLimit(null), 20);
	assert.equal(clampLeaderboardLimit("abc"), 20);
	assert.equal(clampLeaderboardLimit("0"), 20); // 1未満は既定値へフォールバック
	assert.equal(clampLeaderboardLimit("-5"), 20);
	assert.equal(clampLeaderboardLimit("10"), 10);
	assert.equal(clampLeaderboardLimit("100"), 100);
	assert.equal(clampLeaderboardLimit("101"), 100); // 上限クランプ
	assert.equal(clampLeaderboardLimit("99999"), 100);
});

test("レート制限キー生成: 種別:主体:日付 の形式で、日付を渡せば決定的", () => {
	assert.equal(reportMatchRateLimitKey("p1", "2026-09-22"), "report_match:p1:2026-09-22");
	assert.equal(claimRateLimitKey("p1", "2026-09-22"), "claim:p1:2026-09-22");
	assert.equal(ratingQueryRateLimitKey("p1", "2026-09-22"), "rating_query:p1:2026-09-22");
	assert.equal(leaderboardRateLimitKey("1.2.3.4", "2026-09-22"), "leaderboard:1.2.3.4:2026-09-22");
});
