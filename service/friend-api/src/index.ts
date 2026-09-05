/**
 * Tag_Game 自前フレンドリスト用の軽量Webサービス。
 * EOS Product User ID(PUID)をキーにする。EOS Friends API(Epic Account Services
 * ログイン必須)は使わず、Steam/itch.io経由の全プレイヤーが同じ方式でフレンドを
 * 管理できるようにするための恒久的な正(source of truth)。
 *
 * PUIDそのものは公開しない: 発見手段はサーバー側生成の不透明な8文字フレンドコード
 * のみで、PUID/コードの一覧・検索エンドポイントは存在しない。
 *
 * エンドポイント:
 *   POST /sync            -> PUID登録/表示名更新。フレンドコードを返す
 *   POST /send-request     -> フレンドコードから相手にリクエストを送る
 *   POST /list-requests    -> 自分宛ての保留中リクエスト一覧
 *   POST /respond-request  -> リクエストを承諾/拒否する
 *   POST /list-friends     -> 自分のフレンド一覧
 *   POST /remove-friend    -> フレンド解除(双方向)
 */

export interface Env {
	FRIEND_KV: KVNamespace;
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 0/O/1/Iを除外(誤読防止)
const CODE_LENGTH = 8;
const CODE_GEN_MAX_ATTEMPTS = 5;
const RATE_LIMIT_PER_DAY = 50;
const TARGET_INBOX_MAX = 100;

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

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (request.method !== "POST") {
			return json({ error: "method_not_allowed" }, 405);
		}
		switch (url.pathname) {
			case "/sync":
				return handleSync(request, env);
			case "/send-request":
				return handleSendRequest(request, env);
			case "/list-requests":
				return handleListRequests(request, env);
			case "/respond-request":
				return handleRespondRequest(request, env);
			case "/list-friends":
				return handleListFriends(request, env);
			case "/remove-friend":
				return handleRemoveFriend(request, env);
			default:
				return json({ error: "not_found" }, 404);
		}
	},
};

async function handleSync(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	const displayName = String(body?.display_name ?? "");
	if (!puid || !displayName) {
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

async function handleSendRequest(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	const code = String(body?.code ?? "").toUpperCase();
	if (!puid || !code) {
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
	if (!(await checkAndBumpRateLimit(env, ip))) {
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

async function handleListRequests(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	if (!puid) {
		return json({ reason: "invalid_request" }, 400);
	}
	const raw = await env.FRIEND_KV.get(requestsKey(puid));
	const requests: FriendRequest[] = raw ? JSON.parse(raw) : [];
	return json({ requests });
}

async function handleRespondRequest(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	const requestId = String(body?.request_id ?? "");
	const action = String(body?.action ?? "");
	if (!puid || !requestId || (action !== "accept" && action !== "decline")) {
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

async function handleListFriends(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	if (!puid) {
		return json({ reason: "invalid_request" }, 400);
	}
	const raw = await env.FRIEND_KV.get(friendsKey(puid));
	const friends: FriendEntry[] = raw ? JSON.parse(raw) : [];
	return json({ friends });
}

async function handleRemoveFriend(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const puid = String(body?.puid ?? "");
	const friendPuid = String(body?.friend_puid ?? "");
	if (!puid || !friendPuid) {
		return json({ reason: "invalid_request" }, 400);
	}
	await Promise.all([removeFriend(env, puid, friendPuid), removeFriend(env, friendPuid, puid)]);
	return json({ ok: true });
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

/** 1日あたりのIP単位カウンタをインクリメントし、上限以下ならtrueを返す */
async function checkAndBumpRateLimit(env: Env, ip: string): Promise<boolean> {
	const key = rateLimitKey(ip);
	const raw = await env.FRIEND_KV.get(key);
	const count = raw ? parseInt(raw, 10) : 0;
	if (count >= RATE_LIMIT_PER_DAY) {
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
function rateLimitKey(ip: string): string {
	const day = new Date().toISOString().slice(0, 10);
	return `rl:${ip}:${day}`;
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
