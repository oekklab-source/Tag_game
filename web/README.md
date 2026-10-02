# web/

Web 版（GitHub Pages）にだけ置くファイル。Godot の書き出しには含めない（`.gdignore` で Godot から見えなくしてある）。
[.github/workflows/web-build.yml](../.github/workflows/web-build.yml) が `export/web/` へコピーする。

| ファイル | 用途 |
| :-- | :-- |
| `manifest.webmanifest` | 「ホーム画面に追加」したアイコンから起動したときに全画面（アドレスバー無し）にする。iPhone の Safari は Fullscreen API を持たないので、iPhone で全画面にする唯一の方法 |
| `apple-touch-icon.png` (180px) | iPhone のホーム画面のアイコン |
| `icon-192.png` / `icon-512.png` | Android のホーム画面のアイコン |

- **Service Worker は置かない。** Service Worker はビルドをキャッシュするので、
  Web 版だけ古い版数のまま残る事故（2026-09-28、ホスト v11 / Web 版 v9）を起こしやすいため。
- アイコンは `icon.svg` から書き出した仮のもの。正式なアイコン（[docs/OWNER_TASKS.md](../docs/OWNER_TASKS.md) A-3）ができたら差し替える。
  正式タイトルが決まったら `manifest.webmanifest` の `name` / `short_name` と、
  `export_presets.cfg` の `apple-mobile-web-app-title` も差し替える。
