/**
 * friend-api の単体テスト(KAN-103 で新設)。D1/KV や Workers runtime は起動せず、
 * 最小の KV モックで fetch ハンドラを直接呼ぶ。エンドポイント全体の確認は従来どおり
 * README.md の wrangler dev + curl の手動スモークテストで行う。
 *
 * 実行方法: npm test (= node --test src/index.test.ts。Node 22.18 以降は TS をそのまま読めるので
 * tsx などの依存を足していない)
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import worker, { isAcceptedDeployment, type Env } from "./index.ts";

test("isAcceptedDeployment: 一致だけ許可し、未設定・空・不一致・欠落は拒否", () => {
	assert.equal(isAcceptedDeployment("live", { EOS_DEPLOYMENT_ID: "live" }), true);
	assert.equal(isAcceptedDeployment("dev", { EOS_DEPLOYMENT_ID: "live" }), false);
	assert.equal(isAcceptedDeployment(undefined, { EOS_DEPLOYMENT_ID: "live" }), false);
	// 設定漏れのときに「どれでも通す」にならないこと
	assert.equal(isAcceptedDeployment("", { EOS_DEPLOYMENT_ID: "" }), false);
	assert.equal(isAcceptedDeployment(undefined, { EOS_DEPLOYMENT_ID: undefined as unknown as string }), false);
});

/** テスト用の RSA 鍵で、Epic と同じ形の ID トークン(RS256)を作る */
async function makeTokenSigner() {
	const pair = (await crypto.subtle.generateKey(
		{ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
		true,
		["sign", "verify"],
	)) as CryptoKeyPair;
	const pub = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
	const kid = "test-kid";
	const b64u = (b: Uint8Array | string) => Buffer.from(b).toString("base64url");
	return {
		jwks: { keys: [{ kty: pub.kty, n: pub.n, e: pub.e, kid }] },
		async sign(claims: Record<string, unknown>): Promise<string> {
			const head = b64u(JSON.stringify({ alg: "RS256", kid }));
			const body = b64u(JSON.stringify(claims));
			const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(`${head}.${body}`));
			return `${head}.${body}.${b64u(new Uint8Array(sig))}`;
		},
	};
}

test("fetch: pfdid が EOS_DEPLOYMENT_ID と違う本物の署名のトークンは 401、一致すれば通る", async () => {
	const signer = await makeTokenSigner();
	// jwks_cache だけ答え、ほかは「キーなし」を返す最小の KV
	const FRIEND_KV = {
		async get(key: string) {
			return key === "jwks_cache" ? JSON.stringify(signer.jwks) : null;
		},
		async put() {},
		async delete() {},
	};
	const env = { FRIEND_KV, EOS_CLIENT_ID: "client-x", EOS_DEPLOYMENT_ID: "live-dep" } as unknown as Env;
	const claims = (pfdid?: string) => ({
		sub: "p-1",
		iss: "https://api.epicgames.dev/auth/v1/oauth",
		aud: "client-x",
		exp: Math.floor(Date.now() / 1000) + 3600,
		...(pfdid === undefined ? {} : { pfdid }),
	});
	const call = async (token: string) =>
		(await worker.fetch(new Request("https://example.test/list-requests", { method: "POST", headers: { Authorization: `Bearer ${token}` } }), env)).status;

	assert.equal(await call(await signer.sign(claims("live-dep"))), 200);
	assert.equal(await call(await signer.sign(claims("dev-dep"))), 401);
	assert.equal(await call(await signer.sign(claims())), 401);
});
