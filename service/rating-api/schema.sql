-- tag-game-rating-api の D1 スキーマ。
-- 適用方法: npx wrangler d1 execute tag-game-rating-db --file=schema.sql (--local を付ければローカル動作確認用)

-- レート台帳。PUIDごとに1行、サーバー側でのみ更新する(クライアントの自己申告は信用しない)。
CREATE TABLE ratings (
  puid TEXT PRIMARY KEY,
  rating INTEGER NOT NULL DEFAULT 1500,
  matches_played INTEGER NOT NULL DEFAULT 0,
  runner_wins INTEGER NOT NULL DEFAULT 0,
  hunter_wins INTEGER NOT NULL DEFAULT 0,
  highest_rating INTEGER NOT NULL DEFAULT 1500,
  -- /claim-initial-rating (既存プレイヤーのローカルレート取り込み、R-4)で作られた行かどうかの監査用フラグ。
  -- この経路は自己申告値をそのまま受け入れる唯一の窓口(移行時の一度きりの例外)なので、
  -- 後から実データを目視チェックできるよう区別しておく。
  seeded_from_client INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);

-- /leaderboard-top (ORDER BY rating DESC LIMIT ?) 用。
CREATE INDEX idx_ratings_rating ON ratings(rating DESC);

-- 試合報告の冪等性・二重計上防止用ログ。match_id は PRIMARY KEY なので、
-- 同じ試合が(再送・リトライ等で)複数回届いてもINSERTが失敗し二重にレートへ反映されない。
CREATE TABLE match_log (
  match_id TEXT PRIMARY KEY,
  reporter_puid TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
