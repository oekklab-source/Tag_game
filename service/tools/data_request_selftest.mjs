#!/usr/bin/env node
// KAN-22: data_request.mjs をダミーのデータで一通り試す。本番にも、wrangler dev の
// いつものローカルの状態(.wrangler/state)にも触らない(一時フォルダに --persist-to する)。
//
//   node service/tools/data_request_selftest.mjs
//
// ダミーのプレイヤー3人:
//   A … 消す人。B とフレンド、C に申請を送っている、C から申請を受けている
//   B … A のフレンド。試合の記録に A と一緒に載っている
//   C … A と同じ表示名(名前の索引で A だけが抜けて C が残ることを見る)
// 失敗したら大文字の FAIL を出し、終了コード 1 で終わる。

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SERVICE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FRIEND_DIR = join(SERVICE_DIR, "friend-api");
const RATING_DIR = join(SERVICE_DIR, "rating-api");
const SCRIPT = join(SERVICE_DIR, "tools", "data_request.mjs");

const work = mkdtempSync(join(tmpdir(), "tag-data-request-selftest-"));
const persist = join(work, "state");
const local = ["--local", "--persist-to", persist];
const isWin = process.platform === "win32";

const A = "dummy-aaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B = "dummy-bbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const C = "dummy-cccccccccccccccccccccccccccc";
const DAY = new Date().toISOString().slice(0, 10);

let failed = 0;
let passed = 0;
function check(cond, msg) {
	if (cond) { passed++; console.log(`  [OK] ${msg}`); }
	else { failed++; console.log(`  [FAIL] ${msg}`); }
}

function run(cmd, args, cwd) {
	// shell が要るのは npx(.cmd)だけ。node 本体を shell 経由にすると「Program Files」の空白で割れる
	const r = spawnSync(cmd, args, { cwd, encoding: "utf8", shell: isWin && cmd === "npx" });
	if (r.status !== 0) {
		console.log(`FAIL: ${cmd} ${args.join(" ")}\n${r.stdout}\n${r.stderr}`);
		process.exit(1);
	}
	return r.stdout;
}

function kvGet(key) {
	const r = spawnSync("npx", ["wrangler", "kv", "key", "get", key, "--binding", "FRIEND_KV", "--text", ...local],
		{ cwd: FRIEND_DIR, encoding: "utf8", shell: isWin });
	const v = (r.stdout ?? "").replace(/\r?\n$/, "");
	if (r.status !== 0 || v === "Value not found") return null;
	return v;
}

function d1(sql) {
	const file = join(work, "q.sql");
	writeFileSync(file, sql, "utf8");
	const out = run("npx", ["wrangler", "d1", "execute", "tag-game-rating-db", "--file", file, "--json", "--yes", ...local], RATING_DIR);
	return JSON.parse(out.slice(out.indexOf("["))).flatMap((x) => x.results ?? []);
}

try {
	// ---------- ダミーのデータを入れる ----------
	console.log("--- ダミーのデータを入れる ---");
	const stats = (r) => JSON.stringify({ rating: r, matches_played: 3, runner_wins: 1, hunter_wins: 1, highest_rating: r,
		costume_id: "0", costume_colors: [], hat_id: "", updated_at: 1 });
	const kv = [
		[`puid:${A}`, JSON.stringify({ display_name: "TestSame", code: "AAAA2222" })],
		[`puid:${B}`, JSON.stringify({ display_name: "TestB", code: "BBBB3333" })],
		[`puid:${C}`, JSON.stringify({ display_name: "TestSame", code: "CCCC4444" })],
		["code:AAAA2222", A], ["code:BBBB3333", B], ["code:CCCC4444", C],
		["name:TestSame", JSON.stringify([{ puid: A, code: "AAAA2222" }, { puid: C, code: "CCCC4444" }])],
		["name:TestB", JSON.stringify([{ puid: B, code: "BBBB3333" }])],
		[`stats:${A}`, stats(1600)], [`stats:${B}`, stats(1500)],
		[`presence:${A}`, JSON.stringify({ last_seen: 1, heartbeat_day: DAY, heartbeat_count: 1 })],
		[`friends:${A}`, JSON.stringify([{ puid: B, name: "TestB" }])],
		[`friends:${B}`, JSON.stringify([{ puid: A, name: "TestSame" }])],
		[`requests:${C}`, JSON.stringify([{ request_id: "r1", from_puid: A, from_name: "TestSame", created_at: 1 }])],
		[`requests:${A}`, JSON.stringify([{ request_id: "r2", from_puid: C, from_name: "TestSame", created_at: 1 }])],
		[`rlsync:${A}:${DAY}`, "3"], [`rlsearch:${A}:${DAY}`, "1"], [`rlsync:${B}:${DAY}`, "2"],
	];
	const bulk = join(work, "bulk.json");
	writeFileSync(bulk, JSON.stringify(kv.map(([key, value]) => ({ key, value }))), "utf8");
	run("npx", ["wrangler", "kv", "bulk", "put", bulk, "--binding", "FRIEND_KV", ...local], FRIEND_DIR);

	const payload = JSON.stringify({ ok: true, match_id: "m1", replayed: false,
		runner: { puid: A, rating_before: 1600, rating_after: 1610, delta: 10 },
		hunters: [{ puid: B, rating_before: 1500, rating_after: 1490, delta: -10 }] });
	d1(readFileSync(join(RATING_DIR, "schema.sql"), "utf8") + "\n" +
		`INSERT INTO ratings (puid, rating, updated_at) VALUES ('${A}', 1610, 1), ('${B}', 1490, 1);\n` +
		`INSERT INTO match_log VALUES ('m1', '${B}', '${payload}', 1), ('m2', '${A}', '{"target":{"puid":"${B}"}}', 2);\n` +
		`INSERT INTO rate_limit_counters VALUES ('report_match:${A}:${DAY}', 1, 9999999999999), ('report_match:${B}:${DAY}', 1, 9999999999999);\n`);
	console.log("  入れた");

	// ---------- 集めるだけ(開示) ----------
	console.log("--- 集めるだけ(--apply 無し) ---");
	const reportFile = join(work, "report.json");
	run(process.execPath, [SCRIPT, "--code", "AAAA2222", ...local, "--out", reportFile], SERVICE_DIR);
	const rep = JSON.parse(readFileSync(reportFile, "utf8"));
	check(rep.puid === A, "フレンドコードから PUID を引けた");
	check(rep.friend_api.stats?.rating === 1600, "戦績(stats)を集めた");
	check(rep.friend_api.listed_as_friend_by.join() === B, "B のフレンド一覧に載っていることを見つけた");
	check(rep.friend_api.requests_sent_to.join() === C, "C に送った申請を見つけた");
	check(rep.friend_api.rate_limit_keys.length === 2, "本人の PUID が入ったレート制限のキー2件を見つけた");
	check(rep.rating_api.ratings.length === 1 && rep.rating_api.match_log.length === 2, "D1 のレートと試合の記録を集めた");
	check(kvGet(`puid:${A}`) !== null, "--apply 無しでは何も消えていない");

	// ---------- 消す ----------
	console.log("--- 消す(--apply) ---");
	run(process.execPath, [SCRIPT, "--code", "AAAA2222", ...local, "--apply", "--out", join(work, "before_delete.json")], SERVICE_DIR);
	for (const key of [`puid:${A}`, "code:AAAA2222", `stats:${A}`, `presence:${A}`, `friends:${A}`, `requests:${A}`,
		`rlsync:${A}:${DAY}`, `rlsearch:${A}:${DAY}`]) {
		check(kvGet(key) === null, `${key} が消えた`);
	}
	check(kvGet(`friends:${B}`) === "[]", "B のフレンド一覧から A が抜けた");
	check(kvGet(`requests:${C}`) === "[]", "C の申請箱から A の申請が抜けた");
	check(JSON.parse(kvGet("name:TestSame")).map((e) => e.puid).join() === C, "同名の C は名前の索引に残った");
	check(kvGet(`puid:${B}`) !== null && kvGet(`stats:${B}`) !== null && kvGet(`rlsync:${B}:${DAY}`) !== null,
		"B の記録はそのまま");
	check(kvGet(`puid:${C}`) !== null && kvGet("code:CCCC4444") === C, "C の記録はそのまま");

	const ratings = d1("SELECT puid FROM ratings ORDER BY puid;").map((r) => r.puid);
	check(ratings.join() === B, "ratings から A の行だけが消えた");
	const logs = d1("SELECT * FROM match_log ORDER BY match_id;");
	check(logs.length === 2, "match_log の行は残っている(重複計上を防ぐ記録のため)");
	check(logs.every((r) => !JSON.stringify(r).includes(A)), "match_log のどこにも A の PUID が残っていない");
	check(logs[0].payload.includes(B) && logs[1].payload.includes(B), "match_log の B の記録は残っている");
	check(logs[1].reporter_puid === "deleted", "A が報告者だった行は報告者を置き換えた");
	const counters = d1("SELECT rl_key FROM rate_limit_counters;").map((r) => r.rl_key);
	check(counters.length === 1 && counters[0].includes(B), "rate_limit_counters から A の行だけが消えた");

	// ---------- 消した後にもう一度集める ----------
	console.log("--- 消した後(PUID 指定で集め直す) ---");
	const after = JSON.parse(run(process.execPath, [SCRIPT, "--puid", A, ...local], SERVICE_DIR));
	const fa = after.friend_api;
	check(fa.puid_record === null && fa.stats === null && fa.friends.length === 0 && fa.listed_as_friend_by.length === 0
		&& fa.requests_sent_to.length === 0 && fa.rate_limit_keys.length === 0, "friend-api に何も残っていない");
	check(after.rating_api.ratings.length === 0 && after.rating_api.match_log.length === 0
		&& after.rating_api.rate_limit_counters.length === 0, "rating-api に何も残っていない");
} finally {
	rmSync(work, { recursive: true, force: true });
}

console.log(`data_request_selftest 結果: PASS=${passed}, FAIL=${failed}`);
process.exit(failed === 0 ? 0 : 1);
