# リスポーン時の目回りモーション（実装済み）

- 承認された試作と同じ、座った姿勢で頭と上半身が円を描く目回り。
- 頭上を3羽の黄色い小鳥が周回する。
- 0〜2.7秒は目回り、2.7〜3.0秒で立ち上がる。全体で3秒の移動不可ペナルティ。
- 落下復帰だけに適用。通常テレポートやラウンド開始では発動しない。無敵は追加しない。
- ゲームの操作制限と同期仕様はルートの SPEC.md を参照。
- RespawnDizzyは30fps、90フレーム、3秒のワンショット。
- 小鳥は scenes/respawn_birds.gd でゲーム内表示する。
- prototype_respawn.py の通常実行は preview/respawn/ に試作を出力する。
- `--integrate` は既存クリップを保持し、fallguy.blend とゲーム用GLBの目回りクリップを更新する。
- build_fallguy.py の全体再生成にも同じクリップを組み込む。

試作: `blender -b -P tools/blender/prototype_respawn.py`
統合: `blender -b -P tools/blender/prototype_respawn.py -- --integrate`
