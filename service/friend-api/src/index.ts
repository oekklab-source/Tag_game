/**
 * Tag_Game 自前フレンドリスト用の軽量Webサービス。
 * EOS Product User ID(PUID)をキーにする。EOS Friends API(Epic Account Services
 * ログイン必須)は使わず、Steam/itch.io経由の全プレイヤーが同じ方式でフレンドを
 * 管理できるようにするための恒久的な正(source of truth)。
 *
 * 認証: 全エンドポイントはbodyのpuidを一切信用しない。クライアントはEOS Connectが
 * 発行したID Token(JWT)を`Authorization: Bearer <jwt>`で送り、Workerは
 * verifyIdToken()でEpicのJWKS([[JWKS_URL]])を使って署名・exp・iss・audを検証し、
 * トークンのsubクレームを本人のPUIDとして採用する。JWKSエンドポイント/クレーム名は
 * 2026-09-09に実機で取得したEOS Connect ID Tokenを実際にデコードして確認済み
 * (kidが https://api.epicgames.dev/auth/v1/oauth/jwks の鍵と一致)。
 *
 * PUIDそのものは公開しない: 発見手段はサーバー側生成の不透明な8文字フレンドコード、
 * または(ユーザー方針により追加)表示名の完全一致検索のみ。前方一致・部分一致・
 * 一覧列挙につながる仕組みは無い(KVのget()は完全一致lookupしかできない構造なので、
 * search-userも構造的に列挙不可能)。
 *
 * エンドポイント(全てBearerトークン必須、失敗時401):
 *   POST /sync            -> PUID登録/表示名更新 + 名前検索インデックス維持 +
 *     (任意)戦績/スキンのアップロード。フレンドコードを返す
 *   POST /send-request     -> フレンドコードから相手にリクエストを送る
 *   POST /list-requests    -> 自分宛ての保留中リクエスト一覧
 *   POST /respond-request  -> リクエストを承諾/拒否する
 *   POST /list-friends     -> 自分のフレンド一覧(オンライン状態を含む)
 *   POST /remove-friend    -> フレンド解除(双方向)
 *   POST /search-user       -> コード完全一致 or 表示名完全一致でユーザーを検索する
 *     (フレンド追加前のプレビュー用。PUIDは返さない)
 *   POST /heartbeat         -> オンライン在席の生存通知
 *   POST /friend-profile    -> 指定フレンド1人の詳細(オンライン状態・戦績・レート・
 *     最終ログイン・スキン)。呼び出し元と実際にフレンド関係にあるかを必ず検証する
 *
 * 新規4エンドポイントの業務エラーは(認証失敗の401を除き)HTTPステータスを200のまま
 * `{ok:false, reason:"..."}` の形で返す。autoload/http_json_client.gd の post_json()は
 * 200以外のレスポンスをボディごと"network_error"に潰してしまう(既存の/send-requestの
 * 400応答も実際には理由がクライアントに届いていない、既知の制約)ため、理由を実際に
 * UIへ届けたい新規エンドポイントではこの形を踏襲しない。
 *
 * ⑦レーティング戦で逃げる役が対戦中に切断した場合の「敗北精算待ち」記録(暫定実装)。
 * フレンド機能とは無関係だが、PUIDキーのKVを既に持つこのWorkerに相乗りさせる方が
 * 新規Workerを増やすより単純なため、ここに同居させている:
 *   POST /report-penalty   -> ホストが切断検知時に敗北分のレート変動を記録する。
 *     呼び出し元(ホスト)の身元はトークンで検証されるが、対象PUID(body.puid、
 *     切断した相手)はホストの自己申告のままーー既知の制約として受容する
 *     (サーバーは対戦の存在自体を知らないため検証しようがない)。
 *     rating_deltaは負値・絶対値上限([[PENALTY_MIN_DELTA]]..-1)のみ許可し、
 *     トークンPUID単位で1日あたりの報告数に上限を設ける。
 *   POST /consume-penalty  -> 本人クライアントが起動時に一度だけ取得し、同時に削除する
 *     (読み取りと削除を1回のリクエストにまとめているため、取得後クライアント側で
 *     適用する前に落ちると精算されずに消える。二重ペナルティより「たまに精算漏れ」の
 *     方が実害が小さいため、意図的にこちらを選んでいる)
 */

export interface Env {
	FRIEND_KV: KVNamespace;
	EOS_CLIENT_ID: string;
	// ローカル開発専用のバイパス許可フラグ。.dev.vars(gitignore対象)でのみ設定する。
	// wrangler.toml(コミット対象)には絶対に書かない
	ALLOW_DEBUG_AUTH?: string;
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 0/O/1/Iを除外(誤読防止)
const CODE_LENGTH = 8;
const CODE_GEN_MAX_ATTEMPTS = 5;
const RATE_LIMIT_PER_DAY = 50;
const TARGET_INBOX_MAX = 100;
const NAME_INDEX_MAX = 20; // 同じ表示名を持てる人数の上限(1エントリのKV肥大化を防ぐ)
const SEARCH_LIMIT_PER_DAY = 100;
const SYNC_LIMIT_PER_DAY = 500; // 戦績アップロードが相乗りする分、既存のRATE_LIMIT_PER_DAYより広めに取る
// ハートビート未受信のままこの時間を過ぎたらオフライン扱い。クライアント送信間隔(120秒、
// autoload/friend_manager.gd)の2.5倍取り、1〜2回の欠落を許容する
const ONLINE_THRESHOLD_MS = 5 * 60 * 1000;
const HEARTBEAT_LIMIT_PER_DAY = 800; // 120秒間隔なら24時間で720回。欠落再送分の余裕を含む

// EOS Connect ID Token検証。2026-09-09に実機トークンをデコードして確認済み
// (kid/issがこのJWKSエンドポイントと一致することを確認した。推測値ではない)
const JWKS_URL = "https://api.epicgames.dev/auth/v1/oauth/jwks";
const EXPECTED_ISS = "https://api.epicgames.dev/auth/v1/oauth";
const JWKS_CACHE_KEY = "jwks_cache";
const JWKS_CACHE_TTL_SEC = 60 * 60; // 1時間(Epicの鍵ローテーションは頻繁ではない)

const PENALTY_MIN_DELTA = -64;
const PENALTY_MAX_DELTA = -1;
const PENALTY_REPORT_LIMIT_PER_DAY = 20;

interface PuidRecord {
	display_name: string;
	code: string;
}

interface FriendRequest {
	request_id: string;
	from_puid: string;
	from_name: string;
	created_at: number;
}

interface FriendEntry {
	puid: string;
	name: string;
}

// 名前検索インデックス(name:<display_name>)の1エントリ。同名の人が複数いる場合に備え
// 配列で持つ(PuidRecordを都度引くコストを避けるため、コードも一緒に持っておく)
interface NameIndexEntry {
	puid: string;
	code: string;
}

interface PresenceRecord {
	last_seen: number;
}

// フレンドにのみ公開する戦績・レート・スキン。自己申告(未検証)。フレンドにしか見えず、
// 実際のEOSリーダーボード/レーティングには影響しないため、既存の「ジェム残高はローカル
// 権威」と同種の受容リスクとしてdocs/SECURITY_NOTES.mdに記載する
interface StatsRecord {
	rating: number;
	matches_played: number;
	runner_wins: number;
	hunter_wins: number;
	highest_rating: number;
	costume_id: string;
	costume_colors: string[];
	hat_id: string;
	updated_at: number;
}

interface PendingPenalty {
	rating_delta: number;
	reason: string;
	created_at: number;
}

interface Jwk {
	kty: string;
	n: string;
	e: string;
	kid: string;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (request.method !== "POST") {
			return json({ error: "method_not_allowed" }, 405);
		}

		const puid = await verifyIdToken(request, env);
		if (!puid) {
			return json({ error: "unauthorized" }, 401);
		}

		switch (url.pathname) {
			case "/sync":
				return handleSync(request, env, puid);
			case "/send-request":
				return handleSendRequest(request, env, puid);
			case "/list-requests":
				return handleListRequests(env, puid);
			case "/respond-request":
				return handleRespondRequest(request, env, puid);
			case "/list-friends":
				return handleListFriends(env, puid);
			case "/remove-friend":
				return handleRemoveFriend(request, env, puid);
			case "/report-penalty":
				return handleReportPenalty(request, env, puid);
			case "/consume-penalty":
				return handleConsumePenalty(env, puid);
			case "/search-user":
				return handleSearchUser(request, env, puid);
			case "/heartbeat":
				return handleHeartbeat(env, puid);
			case "/friend-profile":
				return handleFriendProfile(request, env, puid);
			default:
				return json({ error: "not_found" }, 404);
		}
	},
};

/** Authorizationヘッダの EOS Connect ID Token(JWT)を検証し、成功したらsubクレーム(PUID)を返す */
async function verifyIdToken(request: Request, env: Env): Promise<string | null> {
	// ローカル開発専用のバイパス。実EOSトークンなしで複数の仮想PUIDを使ったフレンド機能の
	// 一連のフロー(sync→search→send-request→...)を`wrangler dev`上で再現するために使う。
	// env.ALLOW_DEBUG_AUTHは.dev.vars(gitignore対象)でのみ設定するため、本番では
	// 常にundefinedになりこの分岐には入らない
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

/** EpicのJWKSをKVでキャッシュしつつ取得する(kid単位ではなくセット単位でキャッシュ) */
async function getJwks(env: Env): Promise<Jwk[]> {
	const cached = await env.FRIEND_KV.get(JWKS_CACHE_KEY);
	if (cached) {
		try {
			const parsed = JSON.parse(cached) as { keys: Jwk[] };
			if (Array.isArray(parsed.keys)) {
				return parsed.keys;
			}
		} catch {
			// キャッシュが壊れていた場合は再取得にフォールバック
		}
	}
	const res = await fetch(JWKS_URL);
	if (!res.ok) {
		return [];
	}
	const data = (await res.json()) as { keys: Jwk[] };
	await env.FRIEND_KV.put(JWKS_CACHE_KEY, JSON.stringify(data), { expirationTtl: JWKS_CACHE_TTL_SEC });
	return data.keys ?? [];
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

async function handleSync(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const displayName = String(body?.display_name ?? "");
	if (!displayName) {
		return json({ reason: "invalid_request" }, 400);
	}
	if (!(await checkAndBumpRateLimit(env, syncRateLimitKey(puid), SYNC_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" }, 200);
	}

	let code: string;
	const existingRaw = await env.FRIEND_KV.get(puidKey(puid));
	if (existingRaw) {
		const existing: PuidRecord = JSON.parse(existingRaw);
		code = existing.code;
		if (existing.display_name !== displayName) {
			// 検索インデックス(name:<display_name>)を古い名前から外し、新しい名前へ移す。
			// 名前を変えていない多数の呼び出し(profile_updatedはstats変更でも発火する)では
			// このKV書き込み2回を発生させない
			await removeFromNameIndex(env, existing.display_name, puid);
			await addToNameIndex(env, displayName, puid, code);
			existing.display_name = displayName;
			await env.FRIEND_KV.put(puidKey(puid), JSON.stringify(existing));
		}
	} else {
		code = await generateUniqueCode(env);
		const record: PuidRecord = { display_name: displayName, code };
		await env.FRIEND_KV.put(puidKey(puid), JSON.stringify(record));
		await env.FRIEND_KV.put(codeKey(code), puid);
		await addToNameIndex(env, displayName, puid, code);
	}

	await maybeUpdateStats(env, puid, body?.stats);
	return json({ friend_code: code });
}


/** name:<display_name> インデックスへ{puid,code}を追加する。同名エントリの上限(NAME_INDEX_MAX)に
 * 達している場合は追加しない(検索結果が返らないだけで実害は無い。フレンド追加自体はコード直打ちでも可能) */
async function addToNameIndex(env: Env, name: string, puid: string, code: string): Promise<void> {
	const raw = await env.FRIEND_KV.get(nameKey(name));
	const entries: NameIndexEntry[] = raw ? JSON.parse(raw) : [];
	if (entries.some((e) => e.puid === puid)) {
		return;
	}
	if (entries.length >= NAME_INDEX_MAX) {
		return;
	}
	entries.push({ puid, code });
	await env.FRIEND_KV.put(nameKey(name), JSON.stringify(entries));
}


async function removeFromNameIndex(env: Env, name: string, puid: string): Promise<void> {
	const raw = await env.FRIEND_KV.get(nameKey(name));
	if (!raw) {
		return;
	}
	const next = (JSON.parse(raw) as NameIndexEntry[]).filter((e) => e.puid !== puid);
	if (next.length === 0) {
		await env.FRIEND_KV.delete(nameKey(name));
	} else {
		await env.FRIEND_KV.put(nameKey(name), JSON.stringify(next));
	}
}


/** statsが送られてきた場合のみ、内容が実際に変わっていればstats:<puid>を書き換える。
 * 未送信(旧クライアント/送信タイミング前)ではKVに触れない */
async function maybeUpdateStats(env: Env, puid: string, rawStats: unknown): Promise<void> {
	if (!rawStats || typeof rawStats !== "object") {
		return;
	}
	const stats = rawStats as Record<string, unknown>;
	const record: StatsRecord = {
		rating: Number(stats.rating ?? 1500),
		matches_played: Number(stats.matches_played ?? 0),
		runner_wins: Number(stats.runner_wins ?? 0),
		hunter_wins: Number(stats.hunter_wins ?? 0),
		highest_rating: Number(stats.highest_rating ?? 1500),
		costume_id: String(stats.costume_id ?? "default"),
		costume_colors: Array.isArray(stats.costume_colors) ? stats.costume_colors.map(String) : [],
		hat_id: String(stats.hat_id ?? "none"),
		updated_at: Date.now(),
	};
	const prevRaw = await env.FRIEND_KV.get(statsKey(puid));
	if (prevRaw) {
		const prev: StatsRecord = JSON.parse(prevRaw);
		const unchanged = prev.rating === record.rating && prev.matches_played === record.matches_played &&
			prev.runner_wins === record.runner_wins && prev.hunter_wins === record.hunter_wins &&
			prev.highest_rating === record.highest_rating && prev.costume_id === record.costume_id &&
			prev.hat_id === record.hat_id &&
			JSON.stringify(prev.costume_colors) === JSON.stringify(record.costume_colors);
		if (unchanged) {
			return;
		}
	}
	await env.FRIEND_KV.put(statsKey(puid), JSON.stringify(record));
}

async function handleSendRequest(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const code = String(body?.code ?? "").toUpperCase();
	if (!code) {
		return json({ reason: "invalid_request" }, 400);
	}

	const selfRaw = await env.FRIEND_KV.get(puidKey(puid));
	if (!selfRaw) {
		return json({ reason: "not_registered" }, 400);
	}
	const self: PuidRecord = JSON.parse(selfRaw);

	const targetPuid = await env.FRIEND_KV.get(codeKey(code));
	if (!targetPuid) {
		return json({ reason: "invalid_code" }, 400);
	}
	if (targetPuid === puid) {
		return json({ reason: "cannot_add_self" }, 400);
	}

	const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
	if (!(await checkAndBumpRateLimit(env, rateLimitKey(ip)))) {
		return json({ reason: "rate_limited" }, 429);
	}

	const targetRequestsRaw = await env.FRIEND_KV.get(requestsKey(targetPuid));
	const targetRequests: FriendRequest[] = targetRequestsRaw ? JSON.parse(targetRequestsRaw) : [];
	if (targetRequests.length >= TARGET_INBOX_MAX) {
		return json({ reason: "target_inbox_full" }, 429);
	}
	if (!targetRequests.some((r) => r.from_puid === puid)) {
		targetRequests.push({
			request_id: crypto.randomUUID(),
			from_puid: puid,
			from_name: self.display_name,
			created_at: Date.now(),
		});
		await env.FRIEND_KV.put(requestsKey(targetPuid), JSON.stringify(targetRequests));
	}

	const targetRaw = await env.FRIEND_KV.get(puidKey(targetPuid));
	const targetName = targetRaw ? (JSON.parse(targetRaw) as PuidRecord).display_name : "Player";
	return json({ target_name: targetName });
}

async function handleListRequests(env: Env, puid: string): Promise<Response> {
	const raw = await env.FRIEND_KV.get(requestsKey(puid));
	const requests: FriendRequest[] = raw ? JSON.parse(raw) : [];
	return json({ requests });
}

async function handleRespondRequest(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const requestId = String(body?.request_id ?? "");
	const action = String(body?.action ?? "");
	if (!requestId || (action !== "accept" && action !== "decline")) {
		return json({ reason: "invalid_request" }, 400);
	}

	const raw = await env.FRIEND_KV.get(requestsKey(puid));
	const requests: FriendRequest[] = raw ? JSON.parse(raw) : [];
	const idx = requests.findIndex((r) => r.request_id === requestId);
	if (idx === -1) {
		return json({ ok: false, reason: "not_found" }, 404);
	}
	const found = requests[idx];
	requests.splice(idx, 1);
	await env.FRIEND_KV.put(requestsKey(puid), JSON.stringify(requests));

	if (action === "decline") {
		return json({ ok: true });
	}

	// accept: リクエストに記録された名前ではなく、双方の最新の表示名を読み直す
	const [selfRaw, fromRaw] = await Promise.all([
		env.FRIEND_KV.get(puidKey(puid)),
		env.FRIEND_KV.get(puidKey(found.from_puid)),
	]);
	const selfName = selfRaw ? (JSON.parse(selfRaw) as PuidRecord).display_name : "Player";
	const fromName = fromRaw ? (JSON.parse(fromRaw) as PuidRecord).display_name : "Player";

	await Promise.all([
		addFriend(env, puid, { puid: found.from_puid, name: fromName }),
		addFriend(env, found.from_puid, { puid, name: selfName }),
	]);

	return json({ ok: true });
}

async function handleListFriends(env: Env, puid: string): Promise<Response> {
	const raw = await env.FRIEND_KV.get(friendsKey(puid));
	const friends: FriendEntry[] = raw ? JSON.parse(raw) : [];
	// フレンド数分のpresence読み取りが発生するが、無料枠は読み取り1日10万件と大きいため問題ない
	const withOnline = await Promise.all(
		friends.map(async (f) => ({ ...f, online: await isOnline(env, f.puid) })),
	);
	return json({ friends: withOnline });
}


async function isOnline(env: Env, targetPuid: string): Promise<boolean> {
	const raw = await env.FRIEND_KV.get(presenceKey(targetPuid));
	if (!raw) {
		return false;
	}
	const presence: PresenceRecord = JSON.parse(raw);
	return Date.now() - presence.last_seen < ONLINE_THRESHOLD_MS;
}

async function handleRemoveFriend(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const friendPuid = String(body?.friend_puid ?? "");
	if (!friendPuid) {
		return json({ reason: "invalid_request" }, 400);
	}
	await Promise.all([removeFriend(env, puid, friendPuid), removeFriend(env, friendPuid, puid)]);
	return json({ ok: true });
}

async function handleReportPenalty(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const targetPuid = String(body?.puid ?? "");
	const ratingDelta = Number(body?.rating_delta ?? NaN);
	if (!targetPuid || !Number.isFinite(ratingDelta)) {
		return json({ reason: "invalid_request" }, 400);
	}
	if (ratingDelta < PENALTY_MIN_DELTA || ratingDelta > PENALTY_MAX_DELTA) {
		return json({ reason: "invalid_delta" }, 400);
	}
	// レート制限はトークンで検証済みの「報告者」(ホスト)単位。対象PUID(targetPuid)は
	// 引き続きホストの自己申告のままだが、これは既知の制約として受容している(docs/SECURITY_NOTES.md参照)
	if (!(await checkAndBumpRateLimit(env, penaltyReportRateLimitKey(puid), PENALTY_REPORT_LIMIT_PER_DAY))) {
		return json({ reason: "rate_limited" }, 429);
	}
	const record: PendingPenalty = {
		rating_delta: ratingDelta,
		reason: "runner_disconnect",
		created_at: Date.now(),
	};
	await env.FRIEND_KV.put(penaltyKey(targetPuid), JSON.stringify(record));
	return json({ ok: true });
}

async function handleConsumePenalty(env: Env, puid: string): Promise<Response> {
	const raw = await env.FRIEND_KV.get(penaltyKey(puid));
	if (!raw) {
		return json({ pending: false });
	}
	await env.FRIEND_KV.delete(penaltyKey(puid));
	const record: PendingPenalty = JSON.parse(raw);
	return json({ pending: true, rating_delta: record.rating_delta });
}


/** コード完全一致 or 表示名完全一致でユーザーを検索する。KVのget()は完全一致lookupしか
 * できないため、部分一致・前方一致・一覧列挙は構造的に実装できない(意図した制約)。
 * PUIDは返さない(コードと表示名のみ。追加はコードで行う) */
async function handleSearchUser(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const query = String(body?.query ?? "").trim();
	const mode = String(body?.mode ?? "");
	if (!query || (mode !== "code" && mode !== "name")) {
		return json({ ok: false, reason: "invalid_request" }, 200);
	}
	if (!(await checkAndBumpRateLimit(env, searchRateLimitKey(puid), SEARCH_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" }, 200);
	}

	if (mode === "code") {
		const targetPuid = await env.FRIEND_KV.get(codeKey(query.toUpperCase()));
		if (!targetPuid) {
			return json({ ok: true, found: false, matches: [] });
		}
		const raw = await env.FRIEND_KV.get(puidKey(targetPuid));
		if (!raw) {
			return json({ ok: true, found: false, matches: [] });
		}
		const rec: PuidRecord = JSON.parse(raw);
		return json({ ok: true, found: true, matches: [{ code: rec.code, name: rec.display_name }] });
	}

	// mode === "name"
	const raw = await env.FRIEND_KV.get(nameKey(query));
	const entries: NameIndexEntry[] = raw ? JSON.parse(raw) : [];
	return json({
		ok: true,
		found: entries.length > 0,
		matches: entries.map((e) => ({ code: e.code, name: query })),
	});
}


/** クライアントが一定間隔(autoload/friend_manager.gd、既定120秒)ごとに呼ぶ生存通知。
 * KV書き込み予算(無料枠1日1,000件)を消費するため、間隔・上限はservice/friend-api/README.md
 * に明記した実測での見直しを前提にしている */
async function handleHeartbeat(env: Env, puid: string): Promise<Response> {
	if (!(await checkAndBumpRateLimit(env, heartbeatRateLimitKey(puid), HEARTBEAT_LIMIT_PER_DAY))) {
		return json({ ok: false, reason: "rate_limited" }, 200);
	}
	const record: PresenceRecord = { last_seen: Date.now() };
	await env.FRIEND_KV.put(presenceKey(puid), JSON.stringify(record), {
		// オンライン判定はlast_seenの鮮度(ONLINE_THRESHOLD_MS)で行うので、TTLは
		// プレイヤーが長期間戻らなかった場合の放置クリーンアップ用でしかない
		expirationTtl: 60 * 60 * 24 * 30,
	});
	return json({ ok: true });
}


/** フレンド1人の詳細(オンライン状態・戦績・レート・最終ログイン・スキン)。
 * 呼び出し元の友達一覧に対象が実際に含まれているかを必ず検証する(検証を外すと、
 * 知っているPUIDなら誰でも覗ける窓口になってしまう) */
async function handleFriendProfile(request: Request, env: Env, puid: string): Promise<Response> {
	const body = await safeJson(request);
	const friendPuid = String(body?.friend_puid ?? "");
	if (!friendPuid) {
		return json({ ok: false, reason: "invalid_request" }, 200);
	}

	const friendsRaw = await env.FRIEND_KV.get(friendsKey(puid));
	const friends: FriendEntry[] = friendsRaw ? JSON.parse(friendsRaw) : [];
	if (!friends.some((f) => f.puid === friendPuid)) {
		return json({ ok: false, reason: "not_friend" }, 200);
	}

	const [nameRaw, statsRaw, presenceRaw] = await Promise.all([
		env.FRIEND_KV.get(puidKey(friendPuid)),
		env.FRIEND_KV.get(statsKey(friendPuid)),
		env.FRIEND_KV.get(presenceKey(friendPuid)),
	]);
	const name = nameRaw ? (JSON.parse(nameRaw) as PuidRecord).display_name : "Player";
	const lastSeen = presenceRaw ? (JSON.parse(presenceRaw) as PresenceRecord).last_seen : 0;
	const online = lastSeen > 0 && Date.now() - lastSeen < ONLINE_THRESHOLD_MS;

	if (!statsRaw) {
		return json({ ok: true, name, online, last_seen: lastSeen, stats_available: false });
	}
	const stats: StatsRecord = JSON.parse(statsRaw);
	return json({ ok: true, name, online, last_seen: lastSeen, stats_available: true, ...stats });
}


async function addFriend(env: Env, ownerPuid: string, entry: FriendEntry): Promise<void> {
	const raw = await env.FRIEND_KV.get(friendsKey(ownerPuid));
	const friends: FriendEntry[] = raw ? JSON.parse(raw) : [];
	if (!friends.some((f) => f.puid === entry.puid)) {
		friends.push(entry);
		await env.FRIEND_KV.put(friendsKey(ownerPuid), JSON.stringify(friends));
	}
}

async function removeFriend(env: Env, ownerPuid: string, targetPuid: string): Promise<void> {
	const raw = await env.FRIEND_KV.get(friendsKey(ownerPuid));
	if (!raw) {
		return;
	}
	const friends: FriendEntry[] = JSON.parse(raw);
	const next = friends.filter((f) => f.puid !== targetPuid);
	if (next.length !== friends.length) {
		await env.FRIEND_KV.put(friendsKey(ownerPuid), JSON.stringify(next));
	}
}

/** keyのカウンタ(TTL2日、日付境界でリセット)をインクリメントし、上限以下ならtrueを返す */
async function checkAndBumpRateLimit(env: Env, key: string, limit: number = RATE_LIMIT_PER_DAY): Promise<boolean> {
	const raw = await env.FRIEND_KV.get(key);
	const count = raw ? parseInt(raw, 10) : 0;
	if (count >= limit) {
		return false;
	}
	await env.FRIEND_KV.put(key, String(count + 1), { expirationTtl: 60 * 60 * 48 });
	return true;
}

async function generateUniqueCode(env: Env): Promise<string> {
	for (let attempt = 0; attempt < CODE_GEN_MAX_ATTEMPTS; attempt++) {
		const candidate = randomCode();
		const existing = await env.FRIEND_KV.get(codeKey(candidate));
		if (!existing) {
			return candidate;
		}
	}
	// 極めて低確率のフォールバック: それでも衝突したら最後の候補をそのまま使う
	return randomCode();
}

function randomCode(): string {
	const bytes = new Uint8Array(CODE_LENGTH);
	crypto.getRandomValues(bytes);
	let out = "";
	for (const b of bytes) {
		out += CODE_ALPHABET[b % CODE_ALPHABET.length];
	}
	return out;
}

function puidKey(puid: string): string {
	return `puid:${puid}`;
}
function codeKey(code: string): string {
	return `code:${code}`;
}
function requestsKey(puid: string): string {
	return `requests:${puid}`;
}
function friendsKey(puid: string): string {
	return `friends:${puid}`;
}
function penaltyKey(puid: string): string {
	return `penalty:${puid}`;
}
function rateLimitKey(ip: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rl:${ip}:${day}`;
}
function penaltyReportRateLimitKey(reporterPuid: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rlpenalty:${reporterPuid}:${day}`;
}
function nameKey(displayName: string): string {
	return `name:${displayName}`;
}
function presenceKey(puid: string): string {
	return `presence:${puid}`;
}
function statsKey(puid: string): string {
	return `stats:${puid}`;
}
function syncRateLimitKey(puid: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rlsync:${puid}:${day}`;
}
function searchRateLimitKey(puid: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rlsearch:${puid}:${day}`;
}
function heartbeatRateLimitKey(puid: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rlheartbeat:${puid}:${day}`;
}

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
