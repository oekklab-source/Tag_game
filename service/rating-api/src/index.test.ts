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
	computeDisconnectPenaltyId,
	disconnectPenaltyBucket,
	disconnectPenaltyTargetKey,
	isReporterParticipant,
	isValidDisconnectPenaltyRequest,
	isValidHunterPuids,
	isValidMatchId,
	isValidPuid,
	leaderboardRateLimitKey,
	normalizeClaimRating,
	ratingQueryRateLimitKey,
	reportDisconnectPenaltyRateLimitKey,
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

// C-03 R-10(RV-19): PUIDの長さ上限を全エンドポイントで揃える
test("isValidPuid: 空文字と200文字超を拒否", () => {
	assert.equal(isValidPuid("p-runner"), true);
	assert.equal(isValidPuid("a".repeat(200)), true); // 上限ちょうど
	assert.equal(isValidPuid("a".repeat(201)), false);
	assert.equal(isValidPuid(""), false);
	assert.equal(isValidPuid(123), false);
	assert.equal(isValidPuid(null), false);
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
	assert.equal(isValidHunterPuids("runner", ["h1", "a".repeat(201)]), false); // 長さ上限超過(RV-19)
	assert.equal(isValidHunterPuids("runner", "not-an-array"), false);
	assert.equal(isValidHunterPuids("runner", null), false);
});

// C-03 R-10(RV-01): 報告者が参加者であることの検証
test("isReporterParticipant: runner本人・hunterの1人のみ許可", () => {
	assert.equal(isReporterParticipant("p-runner", "p-runner", ["h1", "h2"]), true); // 自分がrunner
	assert.equal(isReporterParticipant("h2", "p-runner", ["h1", "h2"]), true); // 自分がhunter
	assert.equal(isReporterParticipant("p-host", "p-runner", ["h1", "h2"]), false); // 第三者
	assert.equal(isReporterParticipant("", "p-runner", ["h1", "h2"]), false);
});

// C-03 R-10(RV-03): 自己申告レートの受付上限
test("normalizeClaimRating: 上限1500・範囲外と非数値を区別", () => {
	assert.deepEqual(normalizeClaimRating(1500), { ok: true, rating: 1500 }); // 上限ちょうど
	assert.deepEqual(normalizeClaimRating(100), { ok: true, rating: 100 }); // 下限ちょうど
	assert.deepEqual(normalizeClaimRating(1200.4), { ok: true, rating: 1200 }); // 小数は丸める
	assert.deepEqual(normalizeClaimRating(1501), { ok: false, reason: "invalid_rating" });
	assert.deepEqual(normalizeClaimRating(2500), { ok: false, reason: "invalid_rating" }); // 旧上限は不可に
	assert.deepEqual(normalizeClaimRating(99), { ok: false, reason: "invalid_rating" });
	assert.deepEqual(normalizeClaimRating("abc"), { ok: false, reason: "invalid_request" });
	assert.deepEqual(normalizeClaimRating(undefined), { ok: false, reason: "invalid_request" });
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
	assert.equal(reportDisconnectPenaltyRateLimitKey("p1", "2026-09-22"), "disconnect_penalty:p1:2026-09-22");
	// 被害者単位の減点予算は、報告者単位のキーと衝突しない別名前空間であること(C-03 R-10、RV-02)
	assert.equal(disconnectPenaltyTargetKey("p1", "2026-09-22"), "disconnect_penalty_target:p1:2026-09-22");
	assert.notEqual(
		disconnectPenaltyTargetKey("p1", "2026-09-22"),
		reportDisconnectPenaltyRateLimitKey("p1", "2026-09-22"),
	);
});

// C-03 R-5: 切断ペナルティのrating-api統合(旧friend-api /report-penalty・/consume-penalty の後継)

test("isValidDisconnectPenaltyRequest: 基本バリデーション", () => {
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 1500, -12), true);
	assert.equal(isValidDisconnectPenaltyRequest("target", "target", true, 3, 1500, -12), false); // 自己申告(報告者=対象)
	assert.equal(isValidDisconnectPenaltyRequest("", "reporter", true, 3, 1500, -12), false); // 空puid
	assert.equal(isValidDisconnectPenaltyRequest(123, "reporter", true, 3, 1500, -12), false); // puid非文字列
	assert.equal(isValidDisconnectPenaltyRequest("a".repeat(201), "reporter", true, 3, 1500, -12), false); // puid長すぎ(RV-19)
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", "yes", 3, 1500, -12), false); // was_runner非bool
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 0, 1500, -12), false); // hunter_count下限外
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 8, 1500, -12), false); // hunter_count上限外
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3.5, 1500, -12), false); // 非整数
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 50, -12), false); // rating下限外
	// レート値の妥当範囲(100..2500)はclaimの受付上限(1500)とは別概念
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 2500, -12), true);
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 1500, "not-a-number"), false);
});

// C-03 R-10(RV-02c): 小数で別IDを量産する/INTEGER列へ小数を書き込むのを防ぐ
test("isValidDisconnectPenaltyRequest: self_rating・rating_deltaの小数を拒否", () => {
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 1500.0001, -12), false);
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 1500, -12.5), false);
	assert.equal(isValidDisconnectPenaltyRequest("target", "reporter", true, 3, 1500, Number.NaN), false);
});

// C-03 R-10(RV-02a): 決定的IDのmaterialを「被害者PUID + 役割 + 時間バケツ」へ作り直した(v2)
test("disconnectPenaltyBucket: 5分幅で切り替わる", () => {
	const width = 5 * 60 * 1000;
	assert.equal(disconnectPenaltyBucket(0), 0);
	assert.equal(disconnectPenaltyBucket(width - 1), 0);
	assert.equal(disconnectPenaltyBucket(width), 1);
	assert.equal(disconnectPenaltyBucket(width * 3 + 1), 3);
	// 切断検知から数秒以内に報告する生存者同士は、境界をまたがない限り必ず同じバケツに入る
	const t = 1800000123;
	assert.equal(disconnectPenaltyBucket(t), disconnectPenaltyBucket(t + 3000));
});

test("computeDisconnectPenaltyId: 同一バケツ・同一被害者・同一役割なら同一ID", async () => {
	const id1 = await computeDisconnectPenaltyId("p1", true, 100);
	const id2 = await computeDisconnectPenaltyId("p1", true, 100);
	assert.equal(id1, id2);
	assert.match(id1, /^hdp-[0-9a-f]{64}$/);

	const idDiffPuid = await computeDisconnectPenaltyId("p2", true, 100);
	const idDiffRole = await computeDisconnectPenaltyId("p1", false, 100);
	const idNextBucket = await computeDisconnectPenaltyId("p1", true, 101);
	const idPrevBucket = await computeDisconnectPenaltyId("p1", true, 99);
	for (const other of [idDiffPuid, idDiffRole, idNextBucket, idPrevBucket]) {
		assert.notEqual(id1, other);
	}
});
