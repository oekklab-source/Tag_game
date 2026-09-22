/**
 * Tag_Game レート(Elo)のサーバー権威化(C-03)用バックエンド本体。
 *
 * 計算式自体は rating_model.ts (autoload/ranking_manager.gd の1:1移植、R-1で完成済み・
 * 変更不要)をそのまま使う。このファイルはHTTPエンドポイントと永続化(D1)のみを担当する。
 *
 * 認証: service/friend-api/src/index.ts と同じEOS Connect ID Token検証を移植する
 * (verifyIdToken/base64UrlDecode はほぼそのまま複製、getJwks/checkAndBumpRateLimit のみ
 * KVではなくD1(jwks_cache/rate_limit_counters テーブル)を使うよう書き換えている。
 * 理由: KV無料枠はservice/friend-api・service/commerce-apiと共有済みで逼迫気味なため、
 * この新規サービスはD1のみで完結させる設計方針、詳細はREADME.md参照)。
 *
 * 業務エラーは(認証失敗401・method not allowed 405・not found 404を除き)HTTPステータス
 * 200のまま {ok:false, reason:"..."} で返す。autoload/http_json_client.gd の post_json() が
 * 200以外のレスポンスをボディごと"network_error"に潰してしまうため(service/friend-api の
 * 新規エンドポイントと同じ理由・同じ規約)。/leaderboard-top のみ例外で、GETかつ認証不要の
 * 公開エンドポイントであり post_json() を経由しないため、レート制限超過を素直に429で返す。
 *
 * 試合結果報告(/report-match)はホスト単独報告(Option A)。README「マルチプレイの権威モデル」
 * 節が既に「タッチ判定はホストが一元的に行う」と定めている延長。ホストは自身の身元のみ
 * トークンで保証され、誰が参加していたか・誰が捕まえたか・生存時間は自己申告のまま
 * (docs/SECURITY_NOTES.md 項目3の切断ペナルティ報告と同型の構造的限界として受容する。
 * 正式な追記はR-8でまとめて行う)。
 *
 * エンドポイント:
 *   POST /report-match          -> ホストが試合結果を報告。サーバー側でレートを再計算しD1へ反映
 *   POST /claim-initial-rating  -> 初回のみ、クライアント自己申告レートをD1の初期値として登録
 *   POST /rating                -> 自分の現在のサーバー権威レートを取得
 *   GET  /leaderboard-top       -> 認証不要、レート上位N件を取得
 */

import { calculateAllRatingChanges, roundHalfAwayFromZero, tierId, tierName } from "./rating_model.js";

export interface Env {
	DB: D1Database;
	EOS_CLIENT_ID: string;
	// ローカル開発専用のバイパス許可フラグ。.dev.vars(gitignore対象)でのみ設定する。
	// wrangler.toml(コミット対象)には絶対に書かない
	ALLOW_DEBUG_AUTH?: string;
}

interface Jwk {
	kty: string;
	n: string;
	e: string;
	kid: string;
}

const JWKS_URL = "https://api.epicgames.dev/auth/v1/oauth/jwks";
const EXPECTED_ISS = "https://api.epicgames.dev/auth/v1/oauth";
const JWKS_CACHE_TTL_SEC = 60 * 60; // 1時間(Epicの鍵ローテーションは頻繁ではない)

// autoload/game_manager.gd の ROUND_TIME (180.0) / rating_model.ts の MAX_TIME と一致させる
const MAX_TIME = 180.0;
const RATING_FLOOR = 100; // autoload/profile_manager.gd の apply_match_result() のクランプに合わせる
const DEFAULT_RATING = 1500;

// autoload/eos_manager.gd の create_lobby() 既定 max_members=8 が根拠(Runner1人+Hunter最大7人)
const MIN_HUNTERS = 1;
const MAX_HUNTERS = 7;

const CLAIM_MIN_RATING = 100;
const CLAIM_MAX_RATING = 2500;

const MATCH_REPORT_LIMIT_PER_DAY = 300;
const CLAIM_LIMIT_PER_DAY = 10;
const RATING_QUERY_LIMIT_PER_DAY = 1000;
const LEADERBOARD_LIMIT_PER_DAY = 200; // IP単位

const MATCH_ID_RE = /^[A-Za-z0-9_-]{8,128}$/;

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/leaderboard-top") {
			if (request.method !== "GET") {
				return json({ error: "method_not_allowed" }, 405);
			}
			return handleLeaderboardTop(request, env);
		}

		if (request.method !== "POST") {
			return json({ error: "method_not_allowed" }, 405);
		}

		const puid = await verifyIdToken(request, env);
		if (!puid) {
			return json({ error: "unauthorized" }, 401);
		}

		switch (url.pathname) {
			case "/report-match":
				return handleReportMatch(request, env, puid);
			case "/claim-initial-rating":
				return handleClaimInitialRating(request, env, puid);
			case "/rating":
				return handleRating(env, puid);
			default:
				return json({ error: "not_found" }, 404);
		}
	},
};

// ---------------------------------------------------------------------------
// バリデーション用の純粋関数(HTTPやD1に触れない。src/index.test.ts で単体テストする)
// ---------------------------------------------------------------------------

export function isValidMatchId(matchId: unknown): matchId is string {
	return typeof matchId === "string" && MATCH_ID_RE.test(matchId);
}

/** hunter_puids の人数範囲・重複・runner_puidとの重複が無いかを検証する */
export function isValidHunterPuids(runnerPuid: string, hunterPuids: unknown): hunterPuids is string[] {
	if (!Array.isArray(hunterPuids)) return false;
	if (hunterPuids.length < MIN_HUNTERS || hunterPuids.length > MAX_HUNTERS) return false;
	if (hunterPuids.some((p) => typeof p !== "string" || p.length === 0)) return false;
	if (hunterPuids.includes(runnerPuid)) return false;
	return new Set(hunterPuids).size === hunterPuids.length;
}

/** ?limit= クエリパラメータを [1,100] にクランプする。省略/非数値は既定値20にフォールバック */
export function clampLeaderboardLimit(raw: string | null): number {
	const n = raw === null ? NaN : parseInt(raw, 10);
	if (!Number.isFinite(n) || n < 1) return 20;
	return Math.min(n, 100);
}

function dayKey(): string {
	return new Date().toISOString().slice(0, 10);
}
export function reportMatchRateLimitKey(puid: string, day: string = dayKey()): string {
	return `report_match:${puid}:${day}`;
}
export function claimRateLimitKey(puid: string, day: string = dayKey()): string {
	return `claim:${puid}:${day}`;
}
export function ratingQueryRateLimitKey(puid: string, day: string = dayKey()): string {
	return `rating_query:${puid}:${day}`;
}
export function leaderboardRateLimitKey(ip: string, day: string = dayKey()): string {
	return `leaderboard:${ip}:${day}`;
}

// ---------------------------------------------------------------------------
// /report-match
// ---------------------------------------------------------------------------

interface RatingRow {
	rating: number;
	matches_played: number;
	runner_wins: number;
	hunter_wins: number;
	highest_rating: number;
}

interface ParticipantResult {
	puid: string;
	rating_before: number;
	rating_after: number;
	delta: number;
	tier_id: string;
	tier_name: string;
}

interface ReportMatchOk {
	ok: true;
	match_id: string;
	replayed: boolean;
	runner: ParticipantResult;
	hunters: ParticipantResult[];
}

function clampFloor(rating: number): number {
	return Math.max(RATING_FLOOR, rating);
}

async function handleReportMatch(request: Request, env: Env, reporterPuid: string): Promise<Response> {
	const body = await safeJson(request);
	const matchId = body?.match_id;
	const runnerPuid = body?.runner_puid;
	const hunterPuids = body?.hunter_puids;
	const runnerEscaped = body?.runner_escaped;
	const toucherPuid: string | null = body?.toucher_puid ?? null;
	let survivalTime = Number(body?.survival_time);

	if (
		!isValidMatchId(matchId) ||
		typeof runnerPuid !== "string" ||
		!runnerPuid ||
		typeof runnerEscaped !== "boolean" ||
		(toucherPuid !== null && typeof toucherPuid !== "string") ||
		!Number.isFinite(survivalTime)
	) {
		return json({ ok: false, reason: "invalid_request" });
	}
	if (!isValidHunterPuids(runnerPuid, hunterPuids)) {
		return json({ ok: false, reason: "invalid_hunter_count" });
	}
	if (survivalTime < 0 || survivalTime > MAX_TIME) {
		return json({ ok: false, reason: "invalid_survival_time" });
	}
	if (runnerEscaped && toucherPuid !== null) {
		return json({ ok: false, reason: "invalid_toucher" });
	}
	if (toucherPuid !== null && !hunterPuids.includes(toucherPuid)) {
		return json({ ok: false, reason: "invalid_toucher" });
	}

	if (!(await checkAndBumpRateLimit(env, reportMatchRateLimitKey(reporterPuid), MATCH_REPORT_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" });
	}

	// 逃げ切り(runner_escaped)時は生存時間を必ず満額(MAX_TIME)へ正規化する。
	// calculateAllRatingChanges() 自体は survival_time を clamp するだけでこの正規化を
	// 行わない(正規化するのは calculateRatingDelta() ラッパー側だけ、rating_model.ts参照)。
	// ここで複製しないと、短い survival_time を送る改造ホストにスコアを操作されうる。
	if (runnerEscaped) {
		survivalTime = MAX_TIME;
	}

	const allPuids = [runnerPuid, ...hunterPuids];
	const selectStmts = allPuids.map((p) =>
		env.DB.prepare(
			"SELECT rating, matches_played, runner_wins, hunter_wins, highest_rating FROM ratings WHERE puid = ?",
		).bind(p),
	);
	const selectResults = await env.DB.batch<RatingRow>(selectStmts);
	const ratingByPuid = new Map<string, RatingRow>();
	allPuids.forEach((p, i) => {
		const row = selectResults[i].results[0];
		if (row) ratingByPuid.set(p, row);
	});

	const unclaimedPuids = allPuids.filter((p) => !ratingByPuid.has(p));
	if (unclaimedPuids.length > 0) {
		return json({ ok: false, reason: "not_claimed", unclaimed_puids: unclaimedPuids });
	}

	const runnerRow = ratingByPuid.get(runnerPuid)!;
	const hunterRows = hunterPuids.map((p) => ratingByPuid.get(p)!);
	const toucherIndex = toucherPuid === null ? -1 : hunterPuids.indexOf(toucherPuid);

	const calc = calculateAllRatingChanges(
		runnerRow.rating,
		hunterRows.map((r) => r.rating),
		survivalTime,
		toucherIndex,
		true,
	);
	const runnerDelta = roundHalfAwayFromZero(calc.runnerDelta);
	const hunterDeltas = calc.hunterDeltas.map((d) => roundHalfAwayFromZero(d));

	const runnerAfter = clampFloor(runnerRow.rating + runnerDelta);
	const runnerResult: ParticipantResult = {
		puid: runnerPuid,
		rating_before: runnerRow.rating,
		rating_after: runnerAfter,
		delta: runnerAfter - runnerRow.rating,
		tier_id: tierId(runnerAfter),
		tier_name: tierName(runnerAfter),
	};
	const hunterResults: ParticipantResult[] = hunterPuids.map((p, i) => {
		const before = hunterRows[i].rating;
		const after = clampFloor(before + hunterDeltas[i]);
		return {
			puid: p,
			rating_before: before,
			rating_after: after,
			delta: after - before,
			tier_id: tierId(after),
			tier_name: tierName(after),
		};
	});

	const responseBody: ReportMatchOk = {
		ok: true,
		match_id: matchId,
		replayed: false,
		runner: runnerResult,
		hunters: hunterResults,
	};
	const payload = JSON.stringify(responseBody);
	const now = Date.now();
	// runner_escaped=true(Runner勝利)なら runner_wins を、false(捕獲=Hunter勝利)なら
	// 各 hunter_wins を +1 する
	const runnerWinInc = runnerEscaped ? 1 : 0;
	const hunterWinInc = runnerEscaped ? 0 : 1;

	const writeStmts = [
		// match_id は PRIMARY KEY なので、同じ試合が再送されてもここでUNIQUE制約違反となり
		// batch() 全体が失敗する(=以下の ratings UPDATE も一切適用されない冪等性ガード)
		env.DB.prepare(
			"INSERT INTO match_log (match_id, reporter_puid, payload, created_at) VALUES (?, ?, ?, ?)",
		).bind(matchId, reporterPuid, payload, now),
		env.DB.prepare(
			"UPDATE ratings SET rating = ?, matches_played = matches_played + 1, " +
				"runner_wins = runner_wins + ?, highest_rating = MAX(highest_rating, ?), updated_at = ? " +
				"WHERE puid = ?",
		).bind(runnerResult.rating_after, runnerWinInc, runnerResult.rating_after, now, runnerPuid),
		...hunterResults.map((h) =>
			env.DB.prepare(
				"UPDATE ratings SET rating = ?, matches_played = matches_played + 1, " +
					"hunter_wins = hunter_wins + ?, highest_rating = MAX(highest_rating, ?), updated_at = ? " +
					"WHERE puid = ?",
			).bind(h.rating_after, hunterWinInc, h.rating_after, now, h.puid),
		),
	];

	try {
		await env.DB.batch(writeStmts);
	} catch {
		// match_id 重複(同一試合の再送)。再計算はせず、前回確定した結果をそのまま返す
		const prev = await env.DB.prepare("SELECT payload FROM match_log WHERE match_id = ?")
			.bind(matchId)
			.first<{ payload: string }>();
		if (!prev) {
			// 想定外(UNIQUE違反以外の理由でbatchが失敗した場合のフォールバック)
			return json({ ok: false, reason: "invalid_request" });
		}
		const prevResult = JSON.parse(prev.payload) as ReportMatchOk;
		prevResult.replayed = true;
		return json(prevResult);
	}

	return json(responseBody);
}

// ---------------------------------------------------------------------------
// /claim-initial-rating
// ---------------------------------------------------------------------------

async function handleClaimInitialRating(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const rawRating = Number(body?.rating);
	if (!Number.isFinite(rawRating)) {
		return json({ ok: false, reason: "invalid_request" });
	}
	const rating = Math.round(rawRating);
	if (rating < CLAIM_MIN_RATING || rating > CLAIM_MAX_RATING) {
		return json({ ok: false, reason: "invalid_rating" });
	}
	if (!(await checkAndBumpRateLimit(env, claimRateLimitKey(puid), CLAIM_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" });
	}

	const now = Date.now();
	try {
		// puid は PRIMARY KEY なので、既に行がある(=claim済み)場合はここでUNIQUE制約違反になる。
		// 事前SELECTで存在確認してからINSERTするTOCTOU方式ではなく、INSERT失敗そのものを
		// 「既にclaim済み」の判定として使う(match_logの冪等性ガードと同じ考え方)
		await env.DB.prepare(
			"INSERT INTO ratings " +
				"(puid, rating, matches_played, runner_wins, hunter_wins, highest_rating, seeded_from_client, updated_at) " +
				"VALUES (?, ?, 0, 0, 0, ?, 1, ?)",
		)
			.bind(puid, rating, rating, now)
			.run();
	} catch {
		return json({ ok: false, reason: "already_claimed" });
	}
	return json({ ok: true, rating });
}

// ---------------------------------------------------------------------------
// /rating
// ---------------------------------------------------------------------------

async function handleRating(env: Env, puid: string): Promise<Response> {
	if (!(await checkAndBumpRateLimit(env, ratingQueryRateLimitKey(puid), RATING_QUERY_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" });
	}
	const row = await env.DB.prepare(
		"SELECT rating, matches_played, runner_wins, hunter_wins, highest_rating FROM ratings WHERE puid = ?",
	)
		.bind(puid)
		.first<RatingRow>();

	if (!row) {
		// ratings行がまだ無い = /claim-initial-rating 未実施。表示用に既定値1500を返しつつ
		// claimed:false で「まだサーバー権威レートが確定していない」ことをクライアントへ伝える
		return json({
			ok: true,
			claimed: false,
			rating: DEFAULT_RATING,
			tier_id: tierId(DEFAULT_RATING),
			tier_name: tierName(DEFAULT_RATING),
			matches_played: 0,
			runner_wins: 0,
			hunter_wins: 0,
			highest_rating: DEFAULT_RATING,
		});
	}

	return json({
		ok: true,
		claimed: true,
		rating: row.rating,
		tier_id: tierId(row.rating),
		tier_name: tierName(row.rating),
		matches_played: row.matches_played,
		runner_wins: row.runner_wins,
		hunter_wins: row.hunter_wins,
		highest_rating: row.highest_rating,
	});
}

// ---------------------------------------------------------------------------
// /leaderboard-top (認証不要・GET)
// ---------------------------------------------------------------------------

interface LeaderboardRow {
	puid: string;
	rating: number;
	matches_played: number;
}

async function handleLeaderboardTop(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	const limit = clampLeaderboardLimit(url.searchParams.get("limit"));

	// 認証が無いため、レート制限は接続元IP単位(トークンPUIDが無い)
	const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
	if (!(await checkAndBumpRateLimit(env, leaderboardRateLimitKey(ip), LEADERBOARD_LIMIT_PER_DAY))) {
		// このエンドポイントは post_json() を経由しないGETのため、素直に429を返してよい
		return json({ ok: false, reason: "rate_limited" }, 429);
	}

	const { results } = await env.DB.prepare(
		"SELECT puid, rating, matches_played FROM ratings ORDER BY rating DESC LIMIT ?",
	)
		.bind(limit)
		.all<LeaderboardRow>();

	const entries = results.map((r, i) => ({
		rank: i + 1,
		puid: r.puid,
		rating: r.rating,
		tier_id: tierId(r.rating),
		tier_name: tierName(r.rating),
		matches_played: r.matches_played,
	}));

	return new Response(JSON.stringify({ ok: true, entries, generated_at: Date.now() }), {
		status: 200,
		headers: {
			"Content-Type": "application/json",
			// D1読み取り負荷を抑えるためエッジで短時間キャッシュする(認証不要の公開データのため可能)
			"Cache-Control": "public, max-age=30",
		},
	});
}

// ---------------------------------------------------------------------------
// 認証(service/friend-api/src/index.ts からの移植。JWKSキャッシュ先だけKV→D1に変更)
// ---------------------------------------------------------------------------

/** Authorizationヘッダの EOS Connect ID Token(JWT)を検証し、成功したらsubクレーム(PUID)を返す */
async function verifyIdToken(request: Request, env: Env): Promise<string | null> {
	// ローカル開発専用のバイパス。env.ALLOW_DEBUG_AUTHは.dev.vars(gitignore対象)でのみ
	// 設定するため、本番では常にundefinedになりこの分岐には入らない
	if (env.ALLOW_DEBUG_AUTH === "1") {
		const debugPuid = request.headers.get("X-Debug-Puid");
		if (debugPuid) {
			return debugPuid;
		}
	}
	const authHeader = request.headers.get("Authorization") ?? "";
	const match = authHeader.match(/^Bearer\s+(.+)$/);
	if (!match) {
		return null;
	}
	const token = match[1];
	const parts = token.split(".");
	if (parts.length !== 3) {
		return null;
	}
	const [headerB64, payloadB64, signatureB64] = parts;

	let header: { alg?: string; kid?: string };
	let payload: { sub?: string; iss?: string; aud?: string; exp?: number };
	try {
		header = JSON.parse(new TextDecoder().decode(base64UrlDecode(headerB64)));
		payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(payloadB64)));
	} catch {
		return null;
	}

	if (header.alg !== "RS256" || !header.kid) {
		return null;
	}
	if (!payload.sub || payload.iss !== EXPECTED_ISS) {
		return null;
	}
	if (payload.aud !== env.EOS_CLIENT_ID) {
		return null;
	}
	if (!payload.exp || payload.exp * 1000 < Date.now()) {
		return null;
	}

	const jwks = await getJwks(env);
	const jwk = jwks.find((k) => k.kid === header.kid);
	if (!jwk) {
		return null;
	}

	let key: CryptoKey;
	try {
		key = await crypto.subtle.importKey(
			"jwk",
			{ kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
			{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
			false,
			["verify"],
		);
	} catch {
		return null;
	}

	const signedData = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
	const signature = base64UrlDecode(signatureB64);
	const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signedData);
	if (!valid) {
		return null;
	}

	return payload.sub;
}

/**
 * EpicのJWKSをD1(jwks_cacheテーブル、id=1固定の1行)でキャッシュしつつ取得する。
 * service/friend-api版との違い: KVではなくD1を使う(このサービスはD1のみで完結させる
 * 設計方針のため)。加えて、fetch失敗時に古いキャッシュがあればそれへフォールバックする
 * (Epic側の一時的な障害でログインが完全に不能になるのを避ける、friend-api版からの改善点)。
 */
async function getJwks(env: Env): Promise<Jwk[]> {
	const cached = await env.DB.prepare("SELECT keys_json, fetched_at FROM jwks_cache WHERE id = 1").first<{
		keys_json: string;
		fetched_at: number;
	}>();

	if (cached && Date.now() - cached.fetched_at < JWKS_CACHE_TTL_SEC * 1000) {
		const keys = parseJwksJson(cached.keys_json);
		if (keys) return keys;
	}

	try {
		const res = await fetch(JWKS_URL);
		if (!res.ok) {
			throw new Error(`jwks fetch failed: ${res.status}`);
		}
		const data = (await res.json()) as { keys?: Jwk[] };
		if (!Array.isArray(data.keys)) {
			throw new Error("jwks response missing keys");
		}
		const keysJson = JSON.stringify(data);
		await env.DB.prepare(
			"INSERT INTO jwks_cache (id, keys_json, fetched_at) VALUES (1, ?, ?) " +
				"ON CONFLICT(id) DO UPDATE SET keys_json = excluded.keys_json, fetched_at = excluded.fetched_at",
		)
			.bind(keysJson, Date.now())
			.run();
		return data.keys;
	} catch {
		// Epic側の障害等でfetchが失敗した場合、期限切れでも古いキャッシュが残っていればそれで凌ぐ。
		// 無ければ空配列を返し、呼び出し元のverifyIdTokenは鍵が見つからず401になる
		if (cached) {
			const keys = parseJwksJson(cached.keys_json);
			if (keys) return keys;
		}
		return [];
	}
}

function parseJwksJson(raw: string): Jwk[] | null {
	try {
		const parsed = JSON.parse(raw) as { keys?: Jwk[] };
		return Array.isArray(parsed.keys) ? parsed.keys : null;
	} catch {
		return null;
	}
}

function base64UrlDecode(input: string): Uint8Array {
	let b64 = input.replace(/-/g, "+").replace(/_/g, "/");
	while (b64.length % 4 !== 0) {
		b64 += "=";
	}
	const bin = atob(b64);
	const bytes = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) {
		bytes[i] = bin.charCodeAt(i);
	}
	return bytes;
}

// ---------------------------------------------------------------------------
// レート制限(service/friend-api版との違い: KVカウンタではなくD1の rate_limit_counters
// テーブルを使う。キー形式・日次リセットの考え方はfriend-apiと同じ)
// ---------------------------------------------------------------------------

async function checkAndBumpRateLimit(env: Env, key: string, limit: number): Promise<boolean> {
	const row = await env.DB.prepare("SELECT count FROM rate_limit_counters WHERE rl_key = ?")
		.bind(key)
		.first<{ count: number }>();

	if (row) {
		if (row.count >= limit) {
			return false;
		}
		await env.DB.prepare("UPDATE rate_limit_counters SET count = count + 1 WHERE rl_key = ?").bind(key).run();
	} else {
		// KVのexpirationTtlに相当するネイティブTTLがD1には無いため、expires_atは掃除用の目安値
		await env.DB.prepare("INSERT INTO rate_limit_counters (rl_key, count, expires_at) VALUES (?, 1, ?)")
			.bind(key, Date.now() + 48 * 3600 * 1000)
			.run();
	}

	// 期限切れカウンタの掃除。専用のCron Triggerを新設せず、書き込みのついでに低確率で間引く
	if (Math.random() < 0.01) {
		await env.DB.prepare("DELETE FROM rate_limit_counters WHERE expires_at < ?").bind(Date.now()).run();
	}
	return true;
}

// ---------------------------------------------------------------------------
// 共通ヘルパー(service/friend-api/src/index.ts と同一)
// ---------------------------------------------------------------------------

async function safeJson(request: Request): Promise<any> {
	try {
		return await request.json();
	} catch {
		return {};
	}
}

function json(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), {
		status,
		headers: { "Content-Type": "application/json" },
	});
}
