/**
 * Tag_Game 実課金(Steamworks Microtransactions)用の軽量Webサービス。
 * ゲームのP2Pホスティングとは完全に独立。Publisherキーはここにのみ保管し、
 * クライアント(Godot)には一切渡さない。
 *
 * エンドポイント:
 *   POST /init-txn     -> Steamworks ISteamMicroTxn/InitTxn を呼ぶ
 *   POST /finalize-txn -> Steamworks ISteamMicroTxn/FinalizeTxn を呼ぶ
 *
 * TODO(実機確認が必要, Steamworksパートナー承認待ち):
 *   - Steamworks Web API のパラメータ名/レスポンス形式は現行ドキュメントで再確認すること
 *   - AuthenticateUserTicket に渡す ticket_hex は現状クライアント未実装(空文字)なので、
 *     常に auth_ticket_required で失敗する(fail-closed)。GodotSteamの
 *     getAuthSessionTicket() 実装完了後に有効化される
 */

export interface Env {
	PURCHASE_TXNS: KVNamespace;
	STEAM_WEB_API_KEY: string;
}

// クライアント側 CurrencyPackCatalog (autoload/currency_pack_catalog.gd) のミラー。
// クライアントの静的カタログは信用せず、必ずこちらの値でジェム数/Item Definitionを確定する
const PACKS: Record<string, { gems: number; itemDefId: number; amountCents: number }> = {
	small: { gems: 300, itemDefId: 100001, amountCents: 49000 },
	medium: { gems: 800, itemDefId: 100002, amountCents: 122000 },
	large: { gems: 2000, itemDefId: 100003, amountCents: 280000 },
};

const STEAM_API_BASE = "https://partner.steam-api.com";

interface TxnRecord {
	steamId: string;
	packId: string;
	grantedGems: number;
	finalized: boolean;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (request.method !== "POST") {
			return json({ error: "method_not_allowed" }, 405);
		}
		if (url.pathname === "/init-txn") {
			return handleInitTxn(request, env);
		}
		if (url.pathname === "/finalize-txn") {
			return handleFinalizeTxn(request, env);
		}
		return json({ error: "not_found" }, 404);
	},
};

async function handleInitTxn(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const steamId = String(body?.steam_id ?? "");
	const appId = Number(body?.app_id ?? 0);
	const packId = String(body?.pack_id ?? "");
	const ticketHex = String(body?.ticket_hex ?? "");

	const pack = PACKS[packId];
	if (!steamId || !appId || !pack) {
		return json({ reason: "invalid_request" }, 400);
	}

	// なりすまし対策: クライアント申告のsteam_idを、Steamworksのセッションチケットで
	// 検証してから処理する。ticket_hex 未実装のうちは fail-closed で拒否する
	const authOk = await verifySteamTicket(steamId, ticketHex, appId, env);
	if (!authOk) {
		return json({ reason: "auth_ticket_required" }, 401);
	}

	const orderId = crypto.randomUUID();
	const initRes = await fetch(
		`${STEAM_API_BASE}/ISteamMicroTxn/InitTxn/v3/`,
		{
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({
				key: env.STEAM_WEB_API_KEY,
				appid: String(appId),
				orderid: orderId,
				steamid: steamId,
				itemcount: "1",
				language: "japanese",
				currency: "JPY",
				"itemid[0]": String(pack.itemDefId),
				"qty[0]": "1",
				"amount[0]": String(pack.amountCents),
				"description[0]": `${packId} gem pack`,
				"category[0]": "currency",
			}),
		}
	);
	if (!initRes.ok) {
		return json({ reason: "steam_api_error" }, 502);
	}
	const initData: any = await initRes.json();
	const transId = initData?.response?.params?.transid;
	if (!transId) {
		return json({ reason: "steam_api_error" }, 502);
	}

	const record: TxnRecord = { steamId, packId, grantedGems: pack.gems, finalized: false };
	await env.PURCHASE_TXNS.put(orderId, JSON.stringify(record), { expirationTtl: 60 * 60 * 24 });

	return json({ orderid: orderId, transid: transId });
}

async function handleFinalizeTxn(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const orderId = String(body?.orderid ?? "");
	const appId = Number(body?.app_id ?? 0);

	const stored = await env.PURCHASE_TXNS.get(orderId);
	if (!stored) {
		return json({ granted: false, reason: "unknown_order" }, 404);
	}
	const record: TxnRecord = JSON.parse(stored);

	// 冪等性: 既に確定済みなら再度Steamに問い合わせず、同じ結果を返す(リトライ二重付与防止)
	if (record.finalized) {
		return json({ granted: true, granted_gems: record.grantedGems });
	}

	const finalizeRes = await fetch(
		`${STEAM_API_BASE}/ISteamMicroTxn/FinalizeTxn/v2/`,
		{
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({
				key: env.STEAM_WEB_API_KEY,
				appid: String(appId || 0),
				orderid: orderId,
			}),
		}
	);
	if (!finalizeRes.ok) {
		return json({ granted: false, reason: "steam_api_error" }, 502);
	}
	const finalizeData: any = await finalizeRes.json();
	const success = finalizeData?.response?.result === "OK";
	if (!success) {
		return json({ granted: false, reason: "steam_declined" });
	}

	record.finalized = true;
	await env.PURCHASE_TXNS.put(orderId, JSON.stringify(record), { expirationTtl: 60 * 60 * 24 });

	return json({ granted: true, granted_gems: record.grantedGems });
}

async function verifySteamTicket(steamId: string, ticketHex: string, appId: number, env: Env): Promise<boolean> {
	if (!ticketHex) {
		return false;
	}
	const res = await fetch(
		`${STEAM_API_BASE}/ISteamUserAuth/AuthenticateUserTicket/v1/` +
			`?key=${encodeURIComponent(env.STEAM_WEB_API_KEY)}` +
			`&appid=${appId}&ticket=${encodeURIComponent(ticketHex)}`
	);
	if (!res.ok) {
		return false;
	}
	const data: any = await res.json();
	const params = data?.response?.params;
	return params?.result === "OK" && String(params?.steamid) === steamId;
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
