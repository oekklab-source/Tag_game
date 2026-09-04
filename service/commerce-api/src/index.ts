/**
 * Tag_Game 実課金(Stripe Checkout)用の軽量Webサービス。
 * ゲームのP2Pホスティングとは完全に独立。Stripeのsecret keyはここにのみ保管し、
 * クライアント(Godot)には一切渡さない。
 *
 * エンドポイント:
 *   POST /create-checkout-session -> Stripe Checkout Sessionを作成し、決済URLを返す
 *   POST /purchase-status         -> KVに記録された決済ステータスを返す(Stripeへは問い合わせない)
 *   POST /stripe-webhook          -> Stripeからのイベント通知。決済確定の唯一の真実源
 *   GET  /return                  -> Checkout完了/キャンセル後のリダイレクト先の簡易案内ページ
 *
 * 決済確認はWebhook(checkout.session.completed / checkout.session.expired)を
 * 唯一のソースオブトゥルースとする。/purchase-status はクライアントのポーリング用に
 * KVの値をそのまま読むだけで、Stripe APIへ都度問い合わせることはしない。
 */

export interface Env {
	COMMERCE_TXNS: KVNamespace;
	STRIPE_SECRET_KEY: string;
	STRIPE_WEBHOOK_SECRET: string;
}

// クライアント側 CurrencyPackCatalog (autoload/currency_pack_catalog.gd) のミラー。
// クライアントの静的カタログは信用せず、必ずこちらの値でジェム数/Price IDを確定する
const PACKS: Record<string, { gems: number; priceId: string }> = {
	small: { gems: 300, priceId: "price_REPLACE_WITH_REAL_SMALL" },
	medium: { gems: 800, priceId: "price_REPLACE_WITH_REAL_MEDIUM" },
	large: { gems: 2000, priceId: "price_REPLACE_WITH_REAL_LARGE" },
};

const STRIPE_API_BASE = "https://api.stripe.com/v1";

interface TxnRecord {
	packId: string;
	grantedGems: number;
	status: "pending" | "paid" | "expired";
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/stripe-webhook" && request.method === "POST") {
			return handleWebhook(request, env);
		}
		if (url.pathname === "/return") {
			return handleReturn(url);
		}
		if (request.method !== "POST") {
			return json({ error: "method_not_allowed" }, 405);
		}
		if (url.pathname === "/create-checkout-session") {
			return handleCreateCheckoutSession(request, env);
		}
		if (url.pathname === "/purchase-status") {
			return handlePurchaseStatus(request, env);
		}
		return json({ error: "not_found" }, 404);
	},
};

async function handleCreateCheckoutSession(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const packId = String(body?.pack_id ?? "");
	const pack = PACKS[packId];
	if (!pack) {
		return json({ reason: "invalid_request" }, 400);
	}

	const origin = new URL(request.url).origin;
	const expiresAt = Math.floor(Date.now() / 1000) + 1800; // Stripeの expires_at 最小許容値(30分)

	const res = await fetch(`${STRIPE_API_BASE}/checkout/sessions`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
			"Content-Type": "application/x-www-form-urlencoded",
		},
		body: new URLSearchParams({
			mode: "payment",
			"line_items[0][price]": pack.priceId,
			"line_items[0][quantity]": "1",
			success_url: `${origin}/return?status=success`,
			cancel_url: `${origin}/return?status=cancel`,
			expires_at: String(expiresAt),
			"metadata[pack_id]": packId,
		}),
	});
	if (!res.ok) {
		return json({ reason: "stripe_api_error" }, 502);
	}
	const session: any = await res.json();
	if (!session?.id || !session?.url) {
		return json({ reason: "stripe_api_error" }, 502);
	}

	const record: TxnRecord = { packId, grantedGems: pack.gems, status: "pending" };
	await env.COMMERCE_TXNS.put(session.id, JSON.stringify(record), { expirationTtl: 60 * 60 * 24 });

	return json({ orderid: session.id, checkout_url: session.url });
}

async function handlePurchaseStatus(request: Request, env: Env): Promise<Response> {
	const body = await safeJson(request);
	const orderId = String(body?.order_id ?? "");
	if (!orderId) {
		return json({ status: "unknown" }, 400);
	}

	const stored = await env.COMMERCE_TXNS.get(orderId);
	if (!stored) {
		return json({ status: "unknown" }, 404);
	}
	const record: TxnRecord = JSON.parse(stored);
	return json({
		status: record.status,
		granted: record.status === "paid",
		granted_gems: record.grantedGems,
	});
}

async function handleWebhook(request: Request, env: Env): Promise<Response> {
	// 署名検証にraw bodyが必須のため、JSON.parseより先にテキストとして取得する
	const rawBody = await request.text();
	const sigHeader = request.headers.get("Stripe-Signature") ?? "";

	const valid = await verifyStripeSignature(rawBody, sigHeader, env.STRIPE_WEBHOOK_SECRET);
	if (!valid) {
		return json({ error: "invalid_signature" }, 400);
	}

	let event: any;
	try {
		event = JSON.parse(rawBody);
	} catch {
		return json({ error: "invalid_payload" }, 400);
	}

	const sessionId = event?.data?.object?.id;
	if (sessionId) {
		if (event.type === "checkout.session.completed") {
			await markSessionStatus(env, sessionId, "paid");
		} else if (event.type === "checkout.session.expired") {
			await markSessionStatus(env, sessionId, "expired");
		}
		// それ以外のイベント種別は無視する
	}

	// Stripeは非2xxレスポンスを自動リトライするため、未処理イベントも含め常に200を返す
	return json({ received: true });
}

async function markSessionStatus(env: Env, sessionId: string, status: "paid" | "expired"): Promise<void> {
	const stored = await env.COMMERCE_TXNS.get(sessionId);
	if (!stored) {
		return;
	}
	const record: TxnRecord = JSON.parse(stored);
	// 冪等性: 既にpendingでなければ(=確定済みなら)Stripeの再送でも上書きしない
	if (record.status !== "pending") {
		return;
	}
	record.status = status;
	await env.COMMERCE_TXNS.put(sessionId, JSON.stringify(record), { expirationTtl: 60 * 60 * 24 });
}

/** Stripeの `t=<timestamp>,v1=<signature>` 形式のWebhook署名をHMAC-SHA256で検証する */
async function verifyStripeSignature(rawBody: string, sigHeader: string, secret: string): Promise<boolean> {
	const parts: Record<string, string> = {};
	for (const kv of sigHeader.split(",")) {
		const [k, v] = kv.split("=");
		if (k && v) {
			parts[k] = v;
		}
	}
	const timestamp = parts["t"];
	const signature = parts["v1"];
	if (!timestamp || !signature) {
		return false;
	}

	// リプレイ対策: タイムスタンプが現在時刻から大きくずれていれば拒否する(目安5分)
	const nowSec = Math.floor(Date.now() / 1000);
	if (Math.abs(nowSec - Number(timestamp)) > 300) {
		return false;
	}

	const key = await crypto.subtle.importKey(
		"raw",
		new TextEncoder().encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"]
	);
	const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${rawBody}`));
	const expectedHex = [...new Uint8Array(sigBuffer)].map((b) => b.toString(16).padStart(2, "0")).join("");

	return timingSafeEqual(expectedHex, signature);
}

function timingSafeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) {
		return false;
	}
	let result = 0;
	for (let i = 0; i < a.length; i++) {
		result |= a.charCodeAt(i) ^ b.charCodeAt(i);
	}
	return result === 0;
}

function handleReturn(url: URL): Response {
	const status = url.searchParams.get("status");
	const message =
		status === "success"
			? "ご購入ありがとうございます。ゲームのウィンドウに戻ってください。ジェムは自動的に反映されます。"
			: "購入がキャンセルされました。ゲームのウィンドウに戻ってください。";
	const html =
		`<!doctype html><html><head><meta charset="utf-8"><title>Tag Game</title></head>` +
		`<body style="font-family: sans-serif; text-align: center; padding: 3rem;"><p>${message}</p></body></html>`;
	return new Response(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
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
