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
 * (docs/SECURITY_NOTES.md 項目3の切断ペナルティ報告と同型の構造的限界として受容する)。
 * ただしC-03 R-10で「報告者が自分で申告した参加者一覧に含まれること」は必須にした
 * (isReporterParticipant)。残るのは「報告者自身を参加者に含めた架空の試合」だけで、
 * その被害上限は MATCH_REPORT_LIMIT_PER_DAY が担う(docs/SECURITY_NOTES.md 項目7)。
 *
 * エンドポイント:
 *   POST /report-match              -> ホストが試合結果を報告。サーバー側でレートを再計算しD1へ反映
 *   POST /report-disconnect-penalty -> ホストが対戦中の切断(鬼/逃走者/ホスト自身)を報告し、
 *                                       対象1名の敗北分をD1へ直接反映する(C-03 R-5、旧
 *                                       service/friend-api の /report-penalty・/consume-penalty の後継)
 *   POST /claim-initial-rating      -> 初回のみ、クライアント自己申告レートをD1の初期値として登録
 *   POST /rating                    -> 自分の現在のサーバー権威レートを取得
 *   GET  /leaderboard-top           -> 認証不要、レート上位N件を取得
 */

import { buildHunterRatings, calculateAllRatingChanges, roundHalfAwayFromZero, tierId, tierName } from "./rating_model.js";

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

// 「レート値として実在しうる範囲」。self_rating等の妥当性チェックに使う。
// /claim-initial-rating の受付上限(CLAIM_MAX_RATING)とは別概念なので定数も分けてある
// (R-10でclaim上限だけを1500へ下げた際、この範囲まで巻き添えで狭めないため)
const RATING_MIN = RATING_FLOOR;
const RATING_MAX = 2500;

// C-03 R-10(RV-03): 自己申告レートを受け入れる唯一の窓口なので、既定値(1500)より上は
// 名乗れないようにする = 移行では「下げる方向のみ」許す。seeded_from_client=1 の行を
// /leaderboard-top から一定試合数まで除外する対策(下記)と二重で公開ランキングを守る
const CLAIM_MIN_RATING = RATING_MIN;
const CLAIM_MAX_RATING = DEFAULT_RATING;
/** seeded_from_client=1 の行が /leaderboard-top に載るために必要な試合数 (C-03 R-10, RV-03) */
const SEEDED_MIN_MATCHES_FOR_LEADERBOARD = 5;

// C-03 R-10(RV-01): 報告者=参加者の検証を入れても、「自分を参加者に含めた架空の試合」を
// 単独アカウントで報告する経路は構造的に残る(完全に塞ぐにはEOSロビーの実在検証が必要、
// docs/SECURITY_NOTES.md 項目7参照)。実プレイで到達しうる上限(1試合3分 => 150試合で
// 約7.5時間)まで引き下げ、その経路の被害上限を半分にしてある
const MATCH_REPORT_LIMIT_PER_DAY = 150;
const CLAIM_LIMIT_PER_DAY = 10;
const RATING_QUERY_LIMIT_PER_DAY = 1000;
const LEADERBOARD_LIMIT_PER_DAY = 200; // IP単位

// service/friend-api/src/index.ts の PENALTY_MIN_DELTA/PENALTY_MAX_DELTA/
// PENALTY_REPORT_LIMIT_PER_DAY から移設(C-03 R-5)
const PENALTY_MIN_DELTA = -64;
const PENALTY_MAX_DELTA = -1;
const DISCONNECT_PENALTY_LIMIT_PER_DAY = 20;
/** 被害者PUID単位の1日あたり減点予算(Pt)。C-03 R-10(RV-02)、handleReportDisconnectPenalty 参照 */
const DISCONNECT_PENALTY_TARGET_BUDGET_PER_DAY = -PENALTY_MIN_DELTA;
/** 切断ペナルティの決定的ID(v2)が使う時間バケツの幅。C-03 R-10(RV-02) */
const DISCONNECT_PENALTY_BUCKET_MS = 5 * 60 * 1000;
const PUID_MAX_LEN = 200;

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
			case "/report-disconnect-penalty":
				return handleReportDisconnectPenalty(request, env, puid);
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

/** PUIDとして受け付けてよい文字列か。長さ上限は C-03 R-10(RV-19) で全PUIDへ適用した */
export function isValidPuid(puid: unknown): puid is string {
	return typeof puid === "string" && puid.length > 0 && puid.length <= PUID_MAX_LEN;
}

/** hunter_puids の人数範囲・重複・runner_puidとの重複が無いかを検証する */
export function isValidHunterPuids(runnerPuid: string, hunterPuids: unknown): hunterPuids is string[] {
	if (!Array.isArray(hunterPuids)) return false;
	if (hunterPuids.length < MIN_HUNTERS || hunterPuids.length > MAX_HUNTERS) return false;
	if (hunterPuids.some((p) => !isValidPuid(p))) return false;
	if (hunterPuids.includes(runnerPuid)) return false;
	return new Set(hunterPuids).size === hunterPuids.length;
}

/**
 * 報告者が、自分で申告した参加者一覧に含まれているか(C-03 R-10、RV-01)。
 * これを必須にして初めて「第三者が架空の試合をでっち上げ、任意PUIDのレートを一方的に動かす」
 * 経路が塞がる(/leaderboard-top が攻撃対象のPUID一覧をそのまま配っていることもあり、
 * 検証が無いままでは実行コストが極めて低かった)。
 * ホストは必ず runner か hunter のどちらかなので、正常系(autoload/game/rating_report.gd の
 * hunter_puids は player_ids() から runner_id を除いた全員)には影響しない。
 * なお「自分を参加者に含めた架空の試合」の報告自体はこれでも防げず、
 * MATCH_REPORT_LIMIT_PER_DAY による被害上限と docs/SECURITY_NOTES.md 項目7の受容事項でカバーする
 */
export function isReporterParticipant(reporterPuid: string, runnerPuid: string, hunterPuids: string[]): boolean {
	return reporterPuid === runnerPuid || hunterPuids.includes(reporterPuid);
}

/**
 * /report-disconnect-penalty のリクエスト本体を検証する(C-03 R-5)。rating_delta の範囲
 * (PENALTY_MIN_DELTA..PENALTY_MAX_DELTA)は個別のreason("invalid_delta")を返したいため、
 * ここでは検証せず呼び出し元(handleReportDisconnectPenalty)で別途チェックする
 */
export function isValidDisconnectPenaltyRequest(
	targetPuid: unknown,
	reporterPuid: string,
	wasRunner: unknown,
	hunterCount: unknown,
	selfRating: unknown,
	ratingDelta: unknown,
): targetPuid is string {
	if (!isValidPuid(targetPuid)) return false;
	if (targetPuid === reporterPuid) return false;
	if (typeof wasRunner !== "boolean") return false;
	if (typeof hunterCount !== "number" || !Number.isInteger(hunterCount)) return false;
	if (hunterCount < MIN_HUNTERS || hunterCount > MAX_HUNTERS) return false;
	// C-03 R-10(RV-02c): 小数を弾く。self_rating は v2 の決定的IDからは外れたが、
	// rating_delta の小数は ratings.rating(INTEGER列)へそのまま書かれてしまうため整数を必須にする
	if (typeof selfRating !== "number" || !Number.isInteger(selfRating)) return false;
	if (selfRating < RATING_MIN || selfRating > RATING_MAX) return false;
	if (typeof ratingDelta !== "number" || !Number.isInteger(ratingDelta)) return false;
	return true;
}

/** ?limit= クエリパラメータを [1,100] にクランプする。省略/非数値は既定値20にフォールバック */
export function clampLeaderboardLimit(raw: string | null): number {
	const n = raw === null ? NaN : parseInt(raw, 10);
	if (!Number.isFinite(n) || n < 1) return 20;
	return Math.min(n, 100);
}

/**
 * /claim-initial-rating のレート値を正規化する(C-03 R-10、RV-03)。
 * 上限は CLAIM_MAX_RATING(=1500) で、自己申告では既定値より上を名乗れない。
 * invalid_request(数値ですらない)と invalid_rating(範囲外)の区別は既存の応答仕様なので保つ
 */
export function normalizeClaimRating(raw: unknown): { ok: true; rating: number } | { ok: false; reason: string } {
	const n = Number(raw);
	if (!Number.isFinite(n)) return { ok: false, reason: "invalid_request" };
	const rating = Math.round(n);
	if (rating < CLAIM_MIN_RATING || rating > CLAIM_MAX_RATING) return { ok: false, reason: "invalid_rating" };
	return { ok: true, rating };
}

function dayKey(): string {
	return new Date().toISOString().slice(0, 10);
}
export function reportMatchRateLimitKey(puid: string, day: string = dayKey()): string {
	return `report_match:${puid}:${day}`;
}
export function reportDisconnectPenaltyRateLimitKey(puid: string, day: string = dayKey()): string {
	return `disconnect_penalty:${puid}:${day}`;
}
/** 被害者PUID単位の減点予算キー(報告者単位の disconnect_penalty:* とは別枠、C-03 R-10) */
export function disconnectPenaltyTargetKey(targetPuid: string, day: string = dayKey()): string {
	return `disconnect_penalty_target:${targetPuid}:${day}`;
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
	// C-03 R-11: CPU鬼の人数。未指定(旧クライアント)は0として扱う
	const cpuHunterCount = body?.cpu_hunter_count === undefined ? 0 : Number(body.cpu_hunter_count);

	if (
		!isValidMatchId(matchId) ||
		!isValidPuid(runnerPuid) ||
		typeof runnerEscaped !== "boolean" ||
		(toucherPuid !== null && typeof toucherPuid !== "string") ||
		!Number.isFinite(survivalTime)
	) {
		return json({ ok: false, reason: "invalid_request" });
	}
	if (!isValidHunterPuids(runnerPuid, hunterPuids)) {
		return json({ ok: false, reason: "invalid_hunter_count" });
	}
	// C-03 R-11: cpu_hunter_count は報告者が自由に決められる値なので、必ず上限を掛ける。
	// 大きくすると人数補正 O(N) と Kファクターが動くため、無検証だと報酬を操作できてしまう。
	// 人間+CPU の合計が MAX_HUNTERS を超えないことだけを条件にする(クライアント側の
	// 1ラウンド定員 MAX_HUNTERS=3 よりは緩いが、ここはロビー定員由来の上限=7)
	if (
		!Number.isInteger(cpuHunterCount) ||
		cpuHunterCount < 0 ||
		hunterPuids.length + cpuHunterCount > MAX_HUNTERS
	) {
		return json({ ok: false, reason: "invalid_cpu_hunter_count" });
	}
	// C-03 R-10(RV-01): 報告者自身が参加者でない報告は受け付けない
	if (!isReporterParticipant(reporterPuid, runnerPuid, hunterPuids)) {
		return json({ ok: false, reason: "reporter_not_participant" });
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

	// C-03 R-11: CPU鬼のぶんを末尾に足して N をクライアントと揃える。
	// 末尾に足すので hunterDeltas[0..hunterPuids.length-1] は人間と1:1のまま対応し、
	// 下の hunterResults のインデックス参照はそのままでよい。CPUぶんの増減は捨てる
	const calc = calculateAllRatingChanges(
		runnerRow.rating,
		buildHunterRatings(hunterRows.map((r) => r.rating), cpuHunterCount, DEFAULT_RATING),
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
			// UNIQUE違反(同一match_idの再送)ではない = D1の一時障害等。
			// リクエスト不正と区別できる reason を返す(C-03 R-10、RV-18)
			return json({ ok: false, reason: "write_failed" });
		}
		const prevResult = JSON.parse(prev.payload) as ReportMatchOk;
		prevResult.replayed = true;
		return json(prevResult);
	}

	return json(responseBody);
}

// ---------------------------------------------------------------------------
// /report-disconnect-penalty (C-03 R-5)
// ---------------------------------------------------------------------------

interface DisconnectPenaltyOk {
	ok: true;
	match_id: string;
	replayed: boolean;
	target: ParticipantResult;
}

/** 切断イベントの時刻を DISCONNECT_PENALTY_BUCKET_MS 幅のバケツ番号へ落とす(C-03 R-10、RV-02) */
export function disconnectPenaltyBucket(nowMs: number): number {
	return Math.floor(nowMs / DISCONNECT_PENALTY_BUCKET_MS);
}

/**
 * 対戦中の切断イベントに対して決定的なmatch_idを導出する(クライアントには一切導出させず、
 * このID自体を送らせもしない)。ホスト自身が切断した場合に生存者全員が独立に(調整なしで)
 * 同じイベントを報告しても、2件目以降は match_log の UNIQUE 制約で自然に無視される
 * (旧friend-apiの「puidキー単純上書きで冪等」に代わる、C-03の権威モデルに沿った冪等性ガード)。
 *
 * **v2 (C-03 R-10、RV-02)**: v1 は material に hunter_count / self_rating を含めていたが、
 * これらは改造クライアントが自由に変えられる値なので、1リクエストごとに別IDを作って
 * 同一被害者へペナルティを積み増せてしまっていた(旧friend-apiのpuidキー上書きdedupからの退行、
 * 詳細は docs/SECURITY_NOTES.md 項目3)。v2 の material は「被害者PUID + 役割 + 時間バケツ」だけで、
 * 攻撃者が変えられる値は被害者PUID(=狙う相手そのもの)しか残らない。
 * 生存者は切断検知から数秒以内に報告するのでバケツ幅5分(ラウンド長180秒より十分長い)なら
 * 必ず同居するが、境界をまたぐ可能性があるため呼び出し側が前バケツとの2点照合を行う。
 * "v2" をフォーマットに埋め込み、将来material を変える際に旧フォーマットと衝突しないようにする
 */
export async function computeDisconnectPenaltyId(
	targetPuid: string,
	wasRunner: boolean,
	bucket: number,
): Promise<string> {
	const canonical = `hdp:v2:${targetPuid}:${wasRunner ? "runner" : "hunter"}:${bucket}`;
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
	const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
	return `hdp-${hex}`;
}

async function handleReportDisconnectPenalty(request: Request, env: Env, reporterPuid: string): Promise<Response> {
	const body = await safeJson(request);
	const targetPuid = body?.target_puid;
	const wasRunner = body?.was_runner;
	const hunterCount = Number(body?.hunter_count);
	const selfRating = Number(body?.self_rating);
	const ratingDelta = Number(body?.rating_delta);

	if (!isValidDisconnectPenaltyRequest(targetPuid, reporterPuid, wasRunner, hunterCount, selfRating, ratingDelta)) {
		return json({ ok: false, reason: "invalid_request" });
	}
	if (ratingDelta < PENALTY_MIN_DELTA || ratingDelta > PENALTY_MAX_DELTA) {
		return json({ ok: false, reason: "invalid_delta" });
	}
	if (
		!(await checkAndBumpRateLimit(
			env,
			reportDisconnectPenaltyRateLimitKey(reporterPuid),
			DISCONNECT_PENALTY_LIMIT_PER_DAY,
		))
	) {
		return json({ ok: false, reason: "rate_limited" });
	}

	// C-03 R-10(RV-02): dedupを先に確認する。ここで弾かれるケース(= ホスト切断を独立に
	// 報告してきた生存者の2人目以降)は被害者側の減点予算を消費しない。
	// 境界をまたいだ報告を取りこぼさないよう、現バケツと1つ前のバケツの2点で照合する
	const bucket = disconnectPenaltyBucket(Date.now());
	const matchId = await computeDisconnectPenaltyId(targetPuid, wasRunner, bucket);
	const prevBucketMatchId = await computeDisconnectPenaltyId(targetPuid, wasRunner, bucket - 1);
	const already = await env.DB.prepare("SELECT payload FROM match_log WHERE match_id IN (?, ?)")
		.bind(matchId, prevBucketMatchId)
		.first<{ payload: string }>();
	if (already) {
		const prevResult = JSON.parse(already.payload) as DisconnectPenaltyOk;
		prevResult.replayed = true;
		return json(prevResult);
	}

	const row = await env.DB.prepare(
		"SELECT rating, matches_played, runner_wins, hunter_wins, highest_rating FROM ratings WHERE puid = ?",
	)
		.bind(targetPuid)
		.first<RatingRow>();
	if (!row) {
		return json({ ok: false, reason: "not_claimed" });
	}

	// C-03 R-10(RV-02b): 報告者単位のレート制限とは別に、被害者PUID単位でも1日の減点量を
	// -64Pt(=最大ペナルティ1回分。旧friend-apiの「penalty:<puid>キー上書き」と同等の被害上限)に抑える。
	// 攻撃被害の実質的な上限を決めているのはこちらで、決定的ID(v2)は
	// 「同じ実イベントを二重計上しない」冪等性ガードという役割分担
	const targetBudgetKey = disconnectPenaltyTargetKey(targetPuid);
	const penaltyAmount = Math.abs(ratingDelta);
	if (
		!(await checkAndBumpRateLimit(
			env,
			targetBudgetKey,
			DISCONNECT_PENALTY_TARGET_BUDGET_PER_DAY,
			penaltyAmount,
		))
	) {
		return json({ ok: false, reason: "target_daily_cap" });
	}

	const ratingAfter = clampFloor(row.rating + ratingDelta);
	const targetResult: ParticipantResult = {
		puid: targetPuid,
		rating_before: row.rating,
		rating_after: ratingAfter,
		delta: ratingAfter - row.rating,
		tier_id: tierId(ratingAfter),
		tier_name: tierName(ratingAfter),
	};
	const responseBody: DisconnectPenaltyOk = { ok: true, match_id: matchId, replayed: false, target: targetResult };
	const payload = JSON.stringify(responseBody);
	const now = Date.now();

	try {
		await env.DB.batch([
			// match_id は決定的に導出されているため、生存者全員が同じイベントを独立に報告しても
			// ここでUNIQUE制約違反となりbatch全体が失敗する(=以下のUPDATEも一切適用されない)
			env.DB.prepare(
				"INSERT INTO match_log (match_id, reporter_puid, payload, created_at) VALUES (?, ?, ?, ?)",
			).bind(matchId, reporterPuid, payload, now),
			env.DB.prepare(
				"UPDATE ratings SET rating = ?, matches_played = matches_played + 1, " +
					"highest_rating = MAX(highest_rating, ?), updated_at = ? WHERE puid = ?",
			).bind(ratingAfter, ratingAfter, now, targetPuid),
		]);
	} catch {
		// 上のdedup確認とINSERTの間に別の生存者が割り込んだ(UNIQUE違反)か、D1の一時障害。
		// どちらにせよ減点は適用されていないので、確保した被害者側の予算は戻す
		await refundRateLimit(env, targetBudgetKey, penaltyAmount);
		const prev = await env.DB.prepare("SELECT payload FROM match_log WHERE match_id = ?")
			.bind(matchId)
			.first<{ payload: string }>();
		if (!prev) {
			return json({ ok: false, reason: "write_failed" }); // C-03 R-10(RV-18)
		}
		const prevResult = JSON.parse(prev.payload) as DisconnectPenaltyOk;
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
	const normalized = normalizeClaimRating(body?.rating);
	if (!normalized.ok) {
		return json({ ok: false, reason: normalized.reason });
	}
	const rating = normalized.rating;
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

	// C-03 R-10(RV-03): クライアント自己申告で作られた行(seeded_from_client=1)は、
	// 実際に試合をこなすまで公開ランキングに載せない(claim上限1500と二重の対策。
	// seeded_from_client列はR-2で監査用に用意したまま誰も読んでいなかったが、ここで実用途がついた)
	const { results } = await env.DB.prepare(
		"SELECT puid, rating, matches_played FROM ratings " +
			"WHERE seeded_from_client = 0 OR matches_played >= ? ORDER BY rating DESC LIMIT ?",
	)
		.bind(SEEDED_MIN_MATCHES_FOR_LEADERBOARD, limit)
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

/**
 * カウンタを amount だけ進め、上限(limit)を超えなければ true を返す。
 *
 * C-03 R-10(RV-11): 以前は SELECT -> UPDATE の2文だったため、同時リクエストが両方とも
 * 「まだ上限未満」を読んで上限を超えて通過できた。RV-01/RV-02 の被害上限はこのレート制限が
 * 唯一の柱なので、1文のUPSERT(ON CONFLICT ... DO UPDATE ... WHERE)で原子的に判定する。
 * service/friend-api のKV版(get -> put)は同じ書き方ができず非対称になるが、
 * あちらはKVの結果整合性自体が厳密な上限を保証しないため、D1側だけを厳密にしている。
 *
 * amount は切断ペナルティの「被害者PUID単位の減点予算」(Pt単位で消費)でも使う。
 * KVのexpirationTtlに相当するネイティブTTLがD1には無いため、expires_atは掃除用の目安値
 */
async function checkAndBumpRateLimit(env: Env, key: string, limit: number, amount = 1): Promise<boolean> {
	if (amount <= 0 || amount > limit) {
		// 初回INSERTはON CONFLICT節を通らないため、ここで弾かないと1件目だけ上限を超えて通ってしまう
		return false;
	}
	const res = await env.DB.prepare(
		"INSERT INTO rate_limit_counters (rl_key, count, expires_at) VALUES (?, ?, ?) " +
			"ON CONFLICT(rl_key) DO UPDATE SET count = count + ? WHERE count + ? <= ?",
	)
		.bind(key, amount, Date.now() + 48 * 3600 * 1000, amount, amount, limit)
		.run();
	const allowed = (res.meta?.changes ?? 0) > 0;

	// 期限切れカウンタの掃除。専用のCron Triggerを新設せず、書き込みのついでに低確率で間引く
	if (Math.random() < 0.01) {
		await env.DB.prepare("DELETE FROM rate_limit_counters WHERE expires_at < ?").bind(Date.now()).run();
	}
	return allowed;
}

/**
 * checkAndBumpRateLimit() で確保した分を戻す(適用できなかったペナルティの予算を返すため)。
 * カウンタが負にならないよう MAX(0, ...) でクランプする
 */
async function refundRateLimit(env: Env, key: string, amount: number): Promise<void> {
	await env.DB.prepare("UPDATE rate_limit_counters SET count = MAX(0, count - ?) WHERE rl_key = ?")
		.bind(amount, key)
		.run();
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
