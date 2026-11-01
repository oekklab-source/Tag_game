# itch.io ストアページ掲載文(英語)ドラフト

> 執筆: Claude Code(KAN-56 / 6.7、2026-10-27)。[itchio_page_ja.md](itchio_page_ja.md)(KAN-55 / 6.6 修正後)と
> 同じ構成の英語版。日英併記でページに入れるのは KAN-65 / 7.4。
> 用語はゲーム内の英訳([locale/en.po](../../../locale/en.po))に揃えた:
> にげる人 = Runner、おに = Chaser、カモン = Taunt(掛け声は "Come on!")、きせかえ = Wardrobe、
> ジェム = Gems、ソロ練習 = Solo Practice、手がかりなし = No clues、ダイブ = Dive。
> ギミック名はゲーム内に英語表記が無いので、ここで付けた(Manhole Warp ほか)。
> 日本語版との違い: 日本語版の「マリオ風」(KAN-48 / 5.5 で判断待ち)は、英語版では最初から
> 他社 IP に触れない表現にした。日本語版の `NO INTEL` は、ゲーム内の今の表記
> (「手がかりなし」/ "No clues")に合わせた。

---

## 1. Tagline

**If they see you, you're caught. If they don't, you win. Online asymmetric tag: 1 Runner vs 3 Chasers.**

## 2. About

A third-person 3D online game of tag on a bright, colorful, toy-like map.
One **Runner** is chased by three **Chasers** (any empty Chaser slots are filled by CPU Chasers).
The Chasers don't know where the Runner is - **only at the moment they see them**,
and once they lose sight, the trail goes cold fast.
As the Runner, use the map's heights and gimmicks to stay out of sight and survive for 3 minutes.

## 3. How to Play

- At the start of each round, **one Runner** is chosen at random. Everyone else becomes a **Chaser**,
  and CPU Chasers fill any gap up to three (a round is normally 4 players).
- The round opens with an 8-second head start: the Chasers can't move, only the Runner can.
- **The Runner wins** by not getting caught for 3 minutes after the head start.
- **The Chasers win** by actually touching the Runner (real contact, not a distance check).
- While no one sees the Runner, the Chasers know nothing about their position. When one Chaser spots them,
  every Chaser learns only the **zone** the Runner is in - not the exact spot.
  Lose sight, and the clue fades after 16 seconds, back to "No clues".
- You can play alone, too. Start a room by yourself and you're the Runner against three CPU Chasers.

## 4. Controls

`WASD` Move   `Shift` Dash   `Space` Dive (leap forward)   `E` Item
`F` Taunt (`1`/`2`/`3` to pick a style)   `R` Switch Role   `Tab` Pick Runner (host only)
`Enter` Start (host only)   `Esc` Menu

## 5. Features

- **Asymmetric information**: Chasers only see a zone name and how long ago it was spotted. The Runner sees
  the direction and distance to the nearest Chaser, plus a danger warning at the screen edge.
  Each side plays with completely different information.
- **6 kinds of gimmicks**: Manhole Warps, Jump Pads, Dash Panels, Moving Platforms, Rotating Platforms and
  ? Blocks. Just touch them to use them - for escaping or for chasing.
- **A big terraced map**: 160 x 160 m, split into 9 zones. The high ground is reached only by Jump Pads and
  Manholes (up) and slides (down), so the chase plays out in three dimensions.
- **Taunts (emotes)**: the only way Chasers can talk to each other. Pick from 3 styles.
- **Wardrobe**: choose your character's outfit and hat.
- **Rating (Elo)**: your rating moves with your online results (Solo Practice is unrated).
- **Friends**: send and accept requests with Friend Codes, and see who's online.

## 6. System Requirements

Windows 10 / 11 (64-bit). **A keyboard and mouse are required**; gamepads are not supported.
Online play needs an internet connection.

> TODO(KAN-58 / 6.9): 日本語版と同じく、CPU・GPU・メモリ・ストレージの実測値と、ホストする側の前提条件を
> 実測後に書く。

## 7. Notes and Known Limitations

- Windows only for now (no builds for other platforms are included).
- The Windows version is played with keyboard and mouse. (The on-screen touch buttons are for the browser
  version on touch-screen devices, not for the Windows version.)
  > TODO(KAN-61 / 6.12): 日本語版と同じく、ブラウザ版を itch.io に載せることになったら、スマホのタッチ操作と
  > その制約(横向き固定・ホストはできない等)をここに足す。
- Online play connects you to other players. The temporary address a host creates changes every time.
- If your game is out of date, you may not be able to connect because the network versions don't match
  (an error message will tell you). If only one of you has updated, please update to the latest version.

## 8. Purchases

In-game "Gems" can be bought through a payment service provided by [Stripe, Inc.](https://stripe.com/).
Gems can only be used to buy items such as outfits and hats, and cannot be refunded as cash.
For details, see (currently in Japanese):

- [End User License Agreement (EULA)](../../EULA_DRAFT.md)
- [Privacy Policy](../../PRIVACY_POLICY_DRAFT.md)
- [Legal notice under the Japanese Act on Specified Commercial Transactions](../../TOKUSHOHO_DRAFT.md)

## 9. Credits

> 生成 AI の一文は日本語版と同じ範囲(KAN-47。2026-10-25 に Yes・4区分すべてと決定)。
> 根拠は [docs/AI_GENERATED_ASSETS.md](../../AI_GENERATED_ASSETS.md)。

- Made with Godot Engine
- Licenses for the third-party software and fonts we use (cloudflared, Epic Online Services,
  M PLUS Rounded 1c and more) are in the in-game "Credits & Licenses" screen (bottom left of the title screen)
  and in `THIRD_PARTY_LICENSES.txt` / `GODOT_LICENSES.txt` in the downloaded folder.
- Generative AI was used to make this game: the title music, the concept art for the characters
  and costumes (used as references for the 3D models), most of the program code, and the in-game text
  and this page's text.
- This game uses Epic Online Services (EOS) provided by Epic Games, Inc. for matchmaking, rankings,
  friends and other online features. Epic Games, Inc. expressly disclaims all representations, warranties,
  conditions and liabilities, express or implied, in connection with Epic Online Services.

---

## 掲載時の注意(プレースホルダ)

- タイトルは「Reverse Tag!」。本文はタイトル名を書かずに成立させてあるので、ページのタイトル欄にだけ入れればよい。
- 本文の区切りには em dash(—)ではなくハイフン(-)を使った。ゲーム内の英訳も、同梱フォントに em dash が
  無いためハイフンで書いており、それに揃えた(ストアのページ自体はフォントの制約を受けない)。
- 日本語版の文面を直したら、この英語版も同じ箇所を直すこと(構成は1対1で対応している)。
