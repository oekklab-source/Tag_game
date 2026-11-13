# データの開示・削除請求の手順書（KAN-22）

[プライバシーポリシー](PRIVACY_POLICY_DRAFT.md)第10条で約束している「開示・訂正・削除の請求」に、
実際に応えるための手順。対応する人（運営）向け。

- 道具: [service/tools/data_request.mjs](../service/tools/data_request.mjs)（wrangler の CLI で KV と D1 を直接読む・書く）
- 試し方: [service/tools/data_request_selftest.mjs](../service/tools/data_request_selftest.mjs)（ダミーの3人で、集める→消す→消えたかを確かめる。一時フォルダの中だけで動き、本番にも普段のローカルの状態にも触らない）

## 0. 前提

- Cloudflare のアカウントに wrangler でログインできる人だけが実行できる（`npx wrangler whoami` で確認）。
  Worker に削除の API を足していないのは、公開の入口に「他人のデータを消せる」機能を置かないため。
- **`--local` を付けないと本番を読む・書く。** 手順を覚えるまでは、先に selftest を流して動きを見ておく。
- Node.js 18 以上。`service/friend-api` と `service/rating-api` で `npm install` 済みであること。

## 1. 受付

- 窓口: yuya.hamaguchi@solpinto.jp（KAN-14 で決定。プライバシーポリシー第10条・第13条、EULA 第12条と同じ）
- 請求者に書いてもらうもの: ゲーム内の**フレンドコード**（8文字）と、開示か削除か。
- 受け付けた日を記録する（ポリシーで「30日以内に結果を返す」と約束している）。

## 2. 本人確認

フレンドコードは本人の画面に出るが、**フレンドになった相手にも見える**。フレンドコードだけで
削除に応じると、他人のデータを消せてしまう。そこで、**本人にしかできない操作として、表示名を
こちらが指定した文字列に変えてもらう**（2026-11-13 オーナー決定、KAN-22）。開示の請求も同じ手順で確かめる
（開示の JSON にも本人の戦績やフレンド一覧が入るため）。

1. 請求のメールに返信し、確認用の文字列を伝える。文字列は請求ごとに新しく作る `DEL` と数字4桁
   （例: `DEL4821`）。表示名の上限（16文字）に収まり、NG ワードにも当たらない。
   「7日以内に、ゲームの表示名をこの文字列に変え、そのあとフレンド画面を一度開いてください」と頼む。
   フレンド画面を開いたときに表示名がサーバーへ送られる（`FriendManager.sync_with_backend()`）ので、
   開かないと反映されないことがある。
2. 手順 3 のコマンド（`--apply` なし）を流し、`friend_api.puid_record.display_name` が伝えた文字列に
   なっていれば本人とみなす。
3. 7日たっても変わらなければ、本人確認ができなかったと返信して終える。受け付けた日から30日の期限は
   この待ち時間も含むので、返信は受け付けた当日か翌日に出す。
4. 対応の結果を返信するときに、表示名は好きな名前に戻してよいと添える。

比べた手段（採用は3つ目）:

| 手段 | 強さ | メモ |
|---|---|---|
| フレンドコード＋表示名＋おおよそのレート | 弱い | 手順 3 の結果と照らせる。フレンドにはどれも見えている |
| 上に加えて、フレンド一覧に誰がいるか・最後に遊んだおおよその日 | やや弱い | `listed_as_friend_by` と `presence.last_seen` で照らせる |
| 請求のメールを受けたあと、本人にだけ分かる操作をしてもらう（例: 表示名を指定の文字列に変えてもらい、`puid:` の `display_name` が変わったのを見る） | 強い | ゲームの改修は要らない。表示名の変更は `/sync` で KV に反映される |

## 3. 開示（集める）

```powershell
cd <リポジトリ>
node service/tools/data_request.mjs --code ABCD2345 --out request_ABCD2345.json
```

`--apply` を付けなければ何も消さない。出てくる JSON の中身:

| 項目 | 元のデータ |
|---|---|
| `friend_api.puid_record` | 表示名とフレンドコード（`puid:<PUID>`） |
| `friend_api.stats` | フレンドに見せている戦績・レート・見た目（`stats:<PUID>`） |
| `friend_api.presence` | 最後にオンラインだった時刻（`presence:<PUID>`） |
| `friend_api.friends` / `requests_received` | 本人のフレンド一覧・受け取った申請 |
| `friend_api.listed_as_friend_by` / `requests_sent_to` | 本人が**他人の**一覧・申請箱に載っている先（相手の PUID） |
| `friend_api.rate_limit_keys` | キー名に本人の PUID が入ったレート制限のカウンタ（2日で消える） |
| `rating_api.ratings` | レーティング（D1 の `ratings`） |
| `rating_api.match_log` | 本人が載っている試合の記録（D1 の `match_log`） |
| `rating_api.rate_limit_counters` | キー名に本人の PUID が入ったカウンタ |

**請求者に送るときは他人の情報を伏せる。** `listed_as_friend_by` / `requests_sent_to` の PUID と、
`match_log.payload` の中の他の参加者の PUID・レートは、本人の情報ではない。送る前に消すか、
表示名に置き換える。

`rating_api` が `null` のときは、rating-api の本番の D1 がまだ作られていない（`wrangler.toml` の
`database_id` が仮の値）。その間はレーティングのデータは存在しない。

## 4. 削除

```powershell
node service/tools/data_request.mjs --code ABCD2345 --apply --out request_ABCD2345_before_delete.json
```

消す前の内容を `--out` に残してから消す（手違いに気づいたときに戻すため）。この控えも個人情報なので、
対応を終えて30日たったら消す。消す順番と中身:

1. **他人の記録から本人を抜く**: 相手のフレンド一覧（`friends:<相手>`）と、相手の申請箱（`requests:<相手>`）から本人を外す。
2. **名前の索引から本人を抜く**: `name:<表示名>`。同じ名前の他人の行は残す。
3. **本人のキーを消す**: `stats:` `presence:` `friends:` `requests:` `rlsync:` `rlsearch:` `code:`、最後に `puid:`。
   `puid:` を最後にするのは、途中で止まっても同じコマンドを流し直せるようにするため（`--code` で
   引けなくなっていたら `--puid <PUID>` で流す。PUID は 3 の JSON にある）。
4. **D1**: `ratings` の行を消す。`match_log` は**行を残し、本人の PUID だけを `deleted` に置き換える**。
   `match_log` は同じ試合の結果を二重に計上しないための記録（`match_id` が主キー）で、
   一緒に戦った他の人のレートの増減の記録でもあるため、行ごと消すとそちらが壊れる。
   切断ペナルティの `match_id` は本人の PUID などから計算した SHA-256 の値で、PUID そのものは入っていない
   （ただし PUID を知っている人が同じ計算をすれば照合はできる。重複計上の防止に要るので残す）。
   `rate_limit_counters` の本人の行は消す。

消し終わったら、`--apply` を付けずにもう一度流して、どの項目も空（または `null`）になったことを確かめる。

```powershell
node service/tools/data_request.mjs --puid <PUID>
```

## 5. この道具が扱わないもの

| データ | どうするか |
|---|---|
| **EOS Player Data Storage**（クラウドセーブの `profile.json`） | **未対応**。運営側から他人のファイルを消す手段を、Epic の公開資料では確かめられていない。ゲームの中から本人が自分のファイルを消すことは SDK でできる（`PlayerDataStorage.delete_file`）。どうするかは判断のチケットで決める |
| **EOS Stats / Leaderboards**（ランキングに出すレート） | **未対応**。上と同じチケットで扱う |
| 端末の中のファイル（`%APPDATA%\TagGame\`） | 本人がアンインストール（またはフォルダの削除）で消す。ポリシー第10条のとおり |
| commerce-api の取引の記録（`COMMERCE_TXNS`） | 決済の受け渡し用で、24時間で自動的に消える。PUID は持っていない |
| Stripe の決済の記録 | Stripe 側で保管される（法令上の保存義務がある）。ポリシーの決済の節を参照 |
| レート制限の `rl:<IP>:<日付>`（friend-api） | IP アドレスだけで PUID と結びつかない。2日で自動的に消える |

## 6. 走査の費用

本人が他人の一覧・申請箱に載っている先は、`friends:` と `requests:` を**全件走査**して探す
（フレンドは双方向に書かれるが、片側だけ残った壊れたデータも拾うため）。1回の実行で
「キーの一覧の取得（1,000件ごとに1回）＋ 一覧と申請箱の件数ぶんの読み取り」がかかる。
KV の無料枠（読み取り 1日10万回・一覧 1日1,000回）に対して、プレイヤーが数千人までなら問題にならない。
wrangler を1回ずつ起動するので時間はかかる（selftest の3人で約4分）。プレイヤーが増えて遅すぎるようになったら、
相手を本人の `friends:` の一覧だけから辿る形に切り替える。
