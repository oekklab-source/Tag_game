#!/usr/bin/env node
// KAN-22: プレイヤー本人からの開示・削除請求に対応するための運用スクリプト。
// 手順と判断の理由は docs/DATA_DELETION_RUNBOOK.md。必ずそちらを読んでから使う。
//
//   node service/tools/data_request.mjs --code ABCD2345 [--local [--persist-to <dir>]] [--apply] [--out <file.json>]
//   node service/tools/data_request.mjs --puid <PUID>   ...
//
// 既定は「集めて JSON で出すだけ」(開示請求への回答と、削除前の確認を兼ねる)。
// --apply を付けたときだけ削除する。--local を付けなければ**本番**の KV / D1 を読む・書く。
//
// API(Worker)に削除のエンドポイントを足さずに wrangler の CLI で直接いじるのは、
// 削除は月に数件あるかどうかの手作業で、公開の Worker に「他人のデータを消せる」入口を
// 作るほうが危ないため(Cloudflare のアカウントに入れる人だけが実行できる今の形がいちばん狭い)。

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SERVICE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FRIEND_DIR = join(SERVICE_DIR, "friend-api");
const RATING_DIR = join(SERVICE_DIR, "rating-api");
const KV_BINDING = "FRIEND_KV";
const D1_NAME = "tag-game-rating-db";

// friend-api の CODE_ALPHABET / CODE_LENGTH と同じ(0/O/1/I を除いた8文字)
const CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/;
// SQL に文字列として埋め込むので、引用符・空白・LIKE の記号を含まない形だけ受け付ける。
// EOS の PUID は16進32文字だが、テスト用のダミーにも使えるよう少し広くとる
const PUID_RE = /^[A-Za-z0-9-]{1,200}$/;
// 本人の削除後に、他人の記録の中に残す代わりの値(match_log の匿名化に使う)
const DELETED_MARK = "deleted";

// ---------- 引数 ----------

function parseArgs(argv) {
	const o = { code: "", puid: "", local: false, persistTo: "", apply: false, out: "" };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === "--code") o.code = String(argv[++i] ?? "").toUpperCase();
		else if (a === "--puid") o.puid = String(argv[++i] ?? "");
		else if (a === "--local") o.local = true;
		else if (a === "--persist-to") o.persistTo = resolve(String(argv[++i] ?? ""));
		else if (a === "--apply") o.apply = true;
		else if (a === "--out") o.out = resolve(String(argv[++i] ?? ""));
		else die(`知らない引数: ${a}`);
	}
	if (!o.code === !o.puid) die("--code か --puid のどちらか一方を指定する");
	if (o.code && !CODE_RE.test(o.code)) die(`フレンドコードの形が違う: ${o.code}`);
	if (o.puid && !PUID_RE.test(o.puid)) die(`PUID の形が違う: ${o.puid}`);
	if (o.persistTo && !o.local) die("--persist-to は --local と一緒に使う");
	return o;
}

function die(msg) {
	console.error(`ERROR: ${msg}`);
	process.exit(2);
}

// ---------- wrangler 呼び出し ----------

const tmp = mkdtempSync(join(tmpdir(), "tag-data-request-"));
process.on("exit", () => rmSync(tmp, { recursive: true, force: true }));

function wrangler(cwd, args, opts) {
	const full = ["wrangler", ...args];
	if (opts.local) {
		full.push("--local");
		if (opts.persistTo) full.push("--persist-to", opts.persistTo);
	}
	// Windows では npx が .cmd なので shell 経由で起動する。引数は上で形を確かめた値と
	// 一時ファイルのパスだけで、利用者の自由な文字列をシェルに渡すことはない
	const r = spawnSync("npx", full, { cwd, encoding: "utf8", shell: process.platform === "win32" });
	return { ok: r.status === 0, out: r.stdout ?? "", err: r.stderr ?? "" };
}

function kvGet(key, opts) {
	const r = wrangler(FRIEND_DIR, ["kv", "key", "get", key, "--binding", KV_BINDING, "--text"], opts);
	if (!r.ok) {
		// 値が無いときも wrangler は失敗で返す(版によって「Value not found」を標準出力に出す)
		if (/not found/i.test(r.out + r.err)) return null;
		die(`kv get ${key} に失敗:\n${r.err}`);
	}
	const v = r.out.replace(/\r?\n$/, "");
	return v === "Value not found" ? null : v;
}

function kvGetJson(key, opts) {
	const v = kvGet(key, opts);
	return v === null ? null : JSON.parse(v);
}

function kvList(prefix, opts) {
	const r = wrangler(FRIEND_DIR, ["kv", "key", "list", "--binding", KV_BINDING, "--prefix", prefix], opts);
	if (!r.ok) die(`kv list ${prefix} に失敗:\n${r.err}`);
	const start = r.out.indexOf("[");
	return start < 0 ? [] : JSON.parse(r.out.slice(start)).map((k) => k.name);
}

function kvPut(key, value, opts) {
	const file = join(tmp, "value.txt");
	writeFileSync(file, value, "utf8");
	const r = wrangler(FRIEND_DIR, ["kv", "key", "put", key, "--binding", KV_BINDING, "--path", file], opts);
	if (!r.ok) die(`kv put ${key} に失敗:\n${r.err}`);
}

function kvDelete(key, opts) {
	const r = wrangler(FRIEND_DIR, ["kv", "key", "delete", key, "--binding", KV_BINDING], opts);
	if (!r.ok) die(`kv delete ${key} に失敗:\n${r.err}`);
}

/** D1 に SQL を流す。コマンドラインの引用符の扱いが OS ごとに違うので、常にファイル経由で渡す */
function d1(sql, opts) {
	const file = join(tmp, "q.sql");
	writeFileSync(file, sql, "utf8");
	const args = ["d1", "execute", D1_NAME, "--file", file, "--json", "--yes"];
	if (!opts.local) args.push("--remote");
	const r = wrangler(RATING_DIR, args, opts);
	if (!r.ok) die(`d1 execute に失敗:\n${r.err}\n${r.out}`);
	const start = r.out.indexOf("[");
	const parsed = start < 0 ? [] : JSON.parse(r.out.slice(start));
	return parsed.flatMap((x) => x.results ?? []);
}

function ratingDbProvisioned() {
	// rating-api はまだ本番の D1 を作っていない(database_id が仮の値)。
	// その間は本番の D1 に対しては何もしない(wrangler がエラーで止まるだけなので、先に分かるようにする)
	return !/PLACEHOLDER/.test(readFileSync(join(RATING_DIR, "wrangler.toml"), "utf8"));
}

// ---------- 集める ----------

function collect(opts) {
	let puid = opts.puid;
	if (!puid) {
		puid = kvGet(`code:${opts.code}`, opts);
		if (!puid) die(`フレンドコード ${opts.code} の持ち主が見つからない(friend-api に登録が無い)`);
	}
	if (!PUID_RE.test(puid)) die(`KV にあった PUID の形が想定外: ${puid}`);

	const self = kvGetJson(`puid:${puid}`, opts);
	const friendsOwn = kvGetJson(`friends:${puid}`, opts) ?? [];

	// 他人の記録の中にいる本人: 相手のフレンド一覧と、本人が送ってまだ処理されていない申請。
	// フレンドは双方向に書かれるので本人の一覧から辿れるが、片側だけ残った壊れたデータも
	// 拾えるよう、一覧と申請箱は全件を走査する(件数が増えたら runbook の「走査の費用」を参照)
	const friendsOf = [];
	for (const key of kvList("friends:", opts)) {
		if (key === `friends:${puid}`) continue;
		const list = kvGetJson(key, opts) ?? [];
		if (list.some((f) => f.puid === puid)) friendsOf.push({ key, list });
	}
	const requestsSent = [];
	for (const key of kvList("requests:", opts)) {
		if (key === `requests:${puid}`) continue;
		const list = kvGetJson(key, opts) ?? [];
		if (list.some((r) => r.from_puid === puid)) requestsSent.push({ key, list });
	}
	// 本人の PUID がキー名に入っているレート制限のカウンタ(TTL 2日で自然に消えるが、残さない)
	const rateKeys = [`rlsync:${puid}:`, `rlsearch:${puid}:`].flatMap((p) => kvList(p, opts));

	const kv = {
		puid_record: self,
		code: self?.code ?? (opts.code || null),
		stats: kvGetJson(`stats:${puid}`, opts),
		presence: kvGetJson(`presence:${puid}`, opts),
		friends: friendsOwn,
		requests_received: kvGetJson(`requests:${puid}`, opts) ?? [],
		listed_as_friend_by: friendsOf.map((x) => x.key.slice("friends:".length)),
		requests_sent_to: requestsSent.map((x) => x.key.slice("requests:".length)),
		rate_limit_keys: rateKeys,
	};

	let d1Data = null;
	if (opts.local || ratingDbProvisioned()) {
		d1Data = {
			ratings: d1(`SELECT * FROM ratings WHERE puid = '${puid}';`, opts),
			match_log: d1(
				`SELECT match_id, reporter_puid, payload, created_at FROM match_log ` +
				`WHERE reporter_puid = '${puid}' OR instr(payload, '${puid}') > 0;`, opts),
			rate_limit_counters: d1(`SELECT * FROM rate_limit_counters WHERE instr(rl_key, ':${puid}:') > 0;`, opts),
		};
	}
	return { puid, kv, d1: d1Data, _friendsOf: friendsOf, _requestsSent: requestsSent };
}

// ---------- 消す ----------

function apply(found, opts) {
	const { puid, kv } = found;
	const log = [];
	const del = (key) => { kvDelete(key, opts); log.push(`kv delete ${key}`); };

	// 1) 他人の記録から本人を抜く(本人のキーより先に。途中で止まっても本人のキーが残っていれば
	//    もう一度流せば同じ相手を見つけ直せる)
	for (const { key, list } of found._friendsOf) {
		kvPut(key, JSON.stringify(list.filter((f) => f.puid !== puid)), opts);
		log.push(`kv put ${key} (フレンド一覧から本人を外した)`);
	}
	for (const { key, list } of found._requestsSent) {
		kvPut(key, JSON.stringify(list.filter((r) => r.from_puid !== puid)), opts);
		log.push(`kv put ${key} (申請箱から本人の申請を外した)`);
	}
	// 2) 名前検索の索引から本人を抜く(同名の他人の行は残す)
	if (kv.puid_record?.display_name !== undefined) {
		const nameKey = `name:${kv.puid_record.display_name}`;
		const entries = kvGetJson(nameKey, opts) ?? [];
		const next = entries.filter((e) => e.puid !== puid);
		if (next.length === 0) del(nameKey);
		else if (next.length !== entries.length) {
			kvPut(nameKey, JSON.stringify(next), opts);
			log.push(`kv put ${nameKey} (名前の索引から本人を外した)`);
		}
	}
	// 3) 本人のキー
	for (const key of [`stats:${puid}`, `presence:${puid}`, `friends:${puid}`, `requests:${puid}`, ...kv.rate_limit_keys]) {
		del(key);
	}
	if (kv.code) del(`code:${kv.code}`);
	del(`puid:${puid}`); // 最後に消す(これが残っている間は、同じ PUID で流し直せる)

	// 4) D1。ratings は行ごと消す。match_log は試合の重複計上を防ぐ記録(match_id が主キー)
	//    なので行は残し、本人の PUID だけを置き換える(他の参加者のレート変動の記録でもあるため)
	if (found.d1) {
		d1(
			`DELETE FROM ratings WHERE puid = '${puid}';\n` +
			`UPDATE match_log SET payload = replace(payload, '${puid}', '${DELETED_MARK}'), ` +
			`reporter_puid = CASE WHEN reporter_puid = '${puid}' THEN '${DELETED_MARK}' ELSE reporter_puid END ` +
			`WHERE reporter_puid = '${puid}' OR instr(payload, '${puid}') > 0;\n` +
			`DELETE FROM rate_limit_counters WHERE instr(rl_key, ':${puid}:') > 0;\n`, opts);
		log.push("d1: ratings を削除、match_log の PUID を置き換え、rate_limit_counters を削除");
	} else {
		log.push("d1: 本番の D1 がまだ無いので何もしていない");
	}
	return log;
}

// ---------- 本体 ----------

const opts = parseArgs(process.argv.slice(2));
const target = opts.local ? `ローカル${opts.persistTo ? `(${opts.persistTo})` : ""}` : "本番";
console.error(`対象: ${target} / ${opts.code ? `フレンドコード ${opts.code}` : `PUID ${opts.puid}`}`);

const found = collect(opts);
const report = { generated_at: new Date().toISOString(), target, puid: found.puid, friend_api: found.kv, rating_api: found.d1 };
const text = JSON.stringify(report, null, 2);
if (opts.out) {
	writeFileSync(opts.out, text, "utf8");
	console.error(`集めた内容を ${opts.out} に書いた`);
} else {
	console.log(text);
}

if (!opts.apply) {
	console.error("--apply が無いので削除はしていない");
} else {
	for (const line of apply(found, opts)) console.error(line);
	console.error("削除した。もう一度 --apply 無しで流し、何も残っていないことを確かめること");
}
