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
 * PUIDそのものは公開しない: 発見手段はサーバー側生成の不透明な8文字フレンドコード
 * のみで、PUID/コードの一覧・検索エンドポイントは存在しない。
 *
 * エンドポイント(全てBearerトークン必須、失敗時401):
 *   POST /sync            -> PUID登録/表示名更新。フレンドコードを返す
 *   POST /send-request     -> フレンドコードから相手にリクエストを送る
 *   POST /list-requests    -> 自分宛ての保留中リクエスト一覧
 *   POST /respond-request  -> リクエストを承諾/拒否する
 *   POST /list-friends     -> 自分のフレンド一覧
 *   POST /remove-friend    -> フレンド解除(双方向)
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
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 0/O/1/Iを除外(誤読防止)
const CODE_LENGTH = 8;
const CODE_GEN_MAX_ATTEMPTS = 5;
const RATE_LIMIT_PER_DAY = 50;
const TARGET_INBOX_MAX = 100;

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
			default:
				return json({ error: "not_found" }, 404);
		}
	},
};

/** Authorizationヘッダの EOS Connect ID Token(JWT)を検証し、成功したらsubクレーム(PUID)を返す */
async function verifyIdToken(request: Request, env: Env): Promise<string | null> {
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

	const existingRaw = await env.FRIEND_KV.get(puidKey(puid));
	if (existingRaw) {
		const existing: PuidRecord = JSON.parse(existingRaw);
		if (existing.display_name !== displayName) {
			existing.display_name = displayName;
			await env.FRIEND_KV.put(puidKey(puid), JSON.stringify(existing));
		}
		return json({ friend_code: existing.code });
	}

	const code = await generateUniqueCode(env);
	const record: PuidRecord = { display_name: displayName, code };
	await env.FRIEND_KV.put(puidKey(puid), JSON.stringify(record));
	await env.FRIEND_KV.put(codeKey(code), puid);
	return json({ friend_code: code });
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
	return json({ friends });
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
