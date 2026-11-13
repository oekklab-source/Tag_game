-- KAN-81: 公開ランキングをPUIDから表示名へ切り替えるための列追加。
-- 既にデプロイ済みの本番DB用(新規構築は schema.sql に最初から含まれるため不要)。
-- 新しいWorkerをデプロイする「前」に1回だけ流す(列が無いまま新Workerが動くと /leaderboard-top が落ちる):
--   npx wrangler d1 execute tag-game-rating-db --remote --file=migrations/0001_add_display_name.sql
-- 2回流すと duplicate column で失敗する(壊れはしない)。
ALTER TABLE ratings ADD COLUMN display_name TEXT NOT NULL DEFAULT '';
