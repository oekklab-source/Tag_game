# AI 開発ルール一覧（.agents/）

本ディレクトリには、本プロジェクトで協働する AI アシスタント（Anthropic の **Claude Code** と
Google の **Antigravity**）向けの指示・ルールが格納されています。各ファイルの所有・対象・役割は
以下のとおりです。

| ファイル | 主な対象 | 役割 |
|---|---|---|
| [rules/workspace-basic.md](../rules/workspace-basic.md) | Antigravity | 基本システム指示（`trigger: always_on`）。日本語要件・GUI日本語化・推測禁止 |
| [rules/coexistence-rules.md](../rules/coexistence-rules.md) | Antigravity | Claude Codeとの共存・ファイル保護・コード不介入・RPC鉄則の周知 |
| [rules/model-routing-rules.md](../rules/model-routing-rules.md) | Antigravity | モデルとサブエージェントの使い分け（`trigger: always_on`）。Claude側の対応物は`~/.claude/skills/model-routing/SKILL.md` |
| [rules/audio-pipeline-rules.md](../rules/audio-pipeline-rules.md) | 共通（Claude / Antigravity） | 音楽・SE制作規約の正本。フォーマット・出力先の分離・検証事項 |

## Antigravity のワークフロー（.agents/workflows/）

Antigravity（Gemini）に作業を渡すためのスラッシュコマンドです。`/名前` で実行します。
**コードとシーンファイルは変更せず**、成果物を決められた置き場へ出します。

| コマンド | 内容 | 成果物の置き場 |
|---|---|---|
| [/tag-music](tag-music.md) | シーン別BGM/SEの参考トラック生成＋作曲仕様書の執筆 | `docs/concept/audio/<用途>/` |
| [/tag-music-review](tag-music-review.md) | 生成済み参考トラックの客観/主観レビュー（作曲した会話とは別会話で実行）、PASS/NEEDS-REVISION判定 | `docs/concept/audio/<用途>/REVIEW.md` |

> **ワークフローを新規に追加したら、Antigravity で会話を開始し直してください。**
> ワークフローの一覧は**会話の開始時に**システムプロンプトへ差し込まれる仕組みのため
> （Antigravity 本体が `.agents` をワークスペース設定のルートとして走査し、
> `- [slash command] (path): [description]` の形式で列挙する）、
> 会話の途中で足したファイルは、その会話からは見えず「登録されていない」と言われます。
> 新しい会話を開くか、ウィンドウを再読み込み（`Ctrl+Shift+P` -> Reload Window）すれば認識されます。
>
> それでも認識されない場合は、スラッシュを使わずに
> 「`.agents/workflows/<名前>.md` の手順に従って作業してください」と直接指示しても同じです
> （本体の指示も「該当するワークフローファイルを開いて従え」という内容のため）。

### どちらの AI が担当するか

| 仕事 | 担当 | 理由 |
|---|---|---|
| BGM/SEの**参考トラック生成**・作曲仕様書の執筆 | **Antigravity**（`/tag-music`） | Claude Code に音声生成手段が無い |
| ゲームへの実際の組み込み（バス構成・再生コード・シーンへの配置） | **Claude Code** | `.gd`/`.tscn`/`project.godot`の変更はAntigravityが行わない設計にしているため |

## 関連する正本ドキュメント

各 AI は以下も併せて参照します。重複記述を避けるため、各テーマの「正本」は次に集約されています。

- **Claude Code の入口**: リポジトリルートの [CLAUDE.md](../../CLAUDE.md)（プロジェクト情報・運用ルールの正本。Claude Code が自動ロード）
- **ゲーム構成・マルチプレイの権威モデルの正本**: [README.md](../../README.md)
- **音楽・SE制作の正本**: [rules/audio-pipeline-rules.md](../rules/audio-pipeline-rules.md)

## 共通の行動ルール（両 AI 共通）

次のルールは Claude Code（`CLAUDE.md`）と Antigravity（`rules/workspace-basic.md`）の双方に適用されます。
文言は両ファイルで矛盾しないよう揃えてください。

1. ユーザーへの応答・コード解説・提案はすべて**日本語**で行う。
2. アプリの GUI（画面表示テキスト・ボタン・ラベル・アラート等）はすべて**日本語**で構成する（固有名詞や API・URL・ID 等の技術用語を除く）。
3. 指示に曖昧さや情報不足がある場合は**推測で仕様を捏造せず**、「分かりません」と答えるか明確化の質問を行う。要求スコープを越えた変更を勝手に行わない。
