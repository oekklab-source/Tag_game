# サードパーティのライセンス一覧

配布物（Windows 版 `export/windows/` 一式、Web 版 `export/web/` 一式）に入っている、
自作でないソフトウェア・フォントの一覧と、それぞれの表示義務。
2026-10-16 時点の棚卸し（KAN-44）。表示そのもの（クレジット画面・配布フォルダへのライセンス文書の同梱）は
KAN-45（5.2）で行う。ここはその元データ。

**この一覧を更新するとき**: アドオン・フォント・DLL・素材を足したら、この表に1行足す。
Godot 本体の同梱物（§2）は手で書かず、`Engine.get_copyright_info()` の出力から作り直す（手順は §2）。

## 1. 一覧（配布物に入るもの）

| 名前 | 版 | ライセンス | 表示義務 | 配布物での場所 | 入手元・本文 |
|---|---|---|---|---|---|
| Godot Engine | 4.7.2-stable (official, `ed1daf0b`) | MIT (Expat) | 著作権表示とライセンス本文を、配布物の中か付属文書に入れる | `TagGame.exe`（エンジン本体）／ Web 版の `index.wasm` `index.js` | https://godotengine.org/license/ |
| Godot に同梱のサードパーティ（FreeType・ENet・Mbed TLS・HarfBuzz・ICU・libpng・zlib・Ogg Vorbis ほか約100件） | Godot 4.7.2 同梱版 | 各種（§2） | 項目ごとに異なる（§2 の表と §3） | `TagGame.exe` ／ `index.wasm` | `Engine.get_copyright_info()` / `get_license_info()`（§2） |
| Epic Online Services Godot（EOSG） | 2.3.0（`addons/epic-online-services-godot/plugin.cfg`） | MIT | 著作権表示（Copyright (c) 2022 Delano Lourenco）とライセンス本文 | `libeosg.windows.template_release.x86_64.dll`、pck 内の `addons/epic-online-services-godot/*.gdc` | `addons/epic-online-services-godot/LICENSE.md` |
| godot-cpp（GDExtension の C++ バインディング） | EOSG 2.3.0 のビルドに使われた版（未特定） | MIT (Expat) | 著作権表示（Godot Engine contributors）とライセンス本文。Godot 本体と同じ文面なので、Godot の表示に含めれば足りる | `libeosg.windows.template_release.x86_64.dll` に静的リンク（C++ の GDExtension はこれ無しにはビルドできない） | https://github.com/godotengine/godot-cpp |
| EOS SDK（Epic Online Services SDK） | 1.19.1.2（DLL 内の版文字列 `1.19.1.2-53289219`） | Epic Developer Agreements（独自。OSS ではない） | OSS のようなライセンス本文は無い。分かっている義務は、Epic を免責する条項をエンドユーザー向け EULA に入れる義務（第3.1条(c)、`docs/EOS_LEGAL_REVIEW.md` 第2章）。ストアのクレジットにも同じ免責文を載せている（`docs/concept/store/itchio_page_ja.md` §9） | `EOSSDK-Win64-Shipping.dll`（Windows 版のみ。Web 版には入らない） | Epic Developer Portal の契約。文言は `docs/EULA_DRAFT.md` §4 |
| XAudio2 再頒布版（`xaudio2_9redist.dll`） | 1.0.0.1（Microsoft Corporation） | Microsoft ソフトウェア ライセンス条項（XAudio2 再頒布版、NuGet `Microsoft.XAudio2.Redist`） | **未確認**。Microsoft の再頒布可能コードの条項は一般に「アプリと一緒に配る場合だけ再頒布してよい・改変しない・単体で配らない」といった条件だが、この DLL の条項の本文はリポジトリに無く、まだ読んでいない。KAN-45 で NuGet パッケージ同梱の LICENSE を読んで確定すること | `xaudio2_9redist.dll`（Windows 版のみ。EOS SDK の音声機能の依存として EOSG が同梱している。`eosg.gdextension` の `[dependencies]`） | https://www.nuget.org/packages/Microsoft.XAudio2.Redist |
| M PLUS Rounded 1c Bold | Google Fonts 版（`ui/fonts/README.md` の入手元） | SIL Open Font License 1.1 | 著作権表示（Copyright 2016 The Rounded M+ Project Authors.）と OFL 本文をフォントと一緒に配る。**サブセット化は OFL の「改変版」にあたる**。ただし OFL.txt に Reserved Font Name の指定が無いので、同じ名前のまま配ってよい。フォント単体での販売はできない（ゲームに組み込んでの販売は可） | pck 内の `.godot/imported/MPLUSRounded1c-Bold.ttf-*.fontdata`（JIS 第一水準などにサブセット済み） | `ui/fonts/OFL.txt` |
| cloudflared | — | Apache-2.0 | **KAN-38（4.1）で同梱する方針に決まった場合だけ対象**。同梱するなら LICENSE と NOTICE を一緒に配る | 現状は同梱していない（利用者の PC の PATH にあるものを使う） | https://github.com/cloudflare/cloudflared |

### 配布物に入らないもの（参考）

- `service/*`（Cloudflare Workers）・`server/`（Stripe バックエンドの試作）の npm 依存は、こちらのサーバーで動くだけで
  利用者には配らないので、表示義務の対象外。KAN-30 で、配布物（pck）に入らないことも確かめた
- `tools/`・`tests/` の開発用スクリプト（同上）

## 2. Godot 本体と同梱サードパーティ

Godot 4.7.2 の `Engine.get_copyright_info()` から作った表（2026-10-16、この開発機の Godot 4.7.2 で取得。
`Godot Engine` 本体の行と、Godot の貢献者の著作権表示は除いた）。エディタのビルドで取得したので、
Windows 版の書き出しテンプレートには入っていないもの（Android・Wayland・Metal・Embree など）も混ざっている。
どれが実際に入っているかを1件ずつ切り分けるより、**この全件をそのまま表示するのが簡単で確実**
（Godot の公式ドキュメント「Complying with licenses」もこの方法を勧めている）。

作り直すときは、次のスクリプトを `godot --headless --path . --script <これ> -- <出力先>` で流す:

```gdscript
extends SceneTree
func _init():
	var out := FileAccess.open(OS.get_cmdline_user_args()[0], FileAccess.WRITE)
	for c in Engine.get_copyright_info():
		for p in c["parts"]:
			out.store_line("%s\t%s\t%s" % [c["name"], p["license"], " | ".join(p["copyright"])])
	out.close()
	quit()
```

ライセンス本文は `Engine.get_license_info()` が全19種類（Apache-2.0, BSD-2-clause, BSD-3-clause, BSL-1.0,
CC0-1.0, CC-BY-4.0, Expat, glslang, FTL, HarfBuzz, IJG, MPL-2.0, MIT-0, OFL-1.1, Unicode, Unlicense, WOL, X11, Zlib）
を返すので、KAN-45 のクレジット画面ではこれをそのまま表示すればよい。

| 名前 | ライセンス | 著作権者 |
|---|---|---|
| Bullet Continuous Collision Detection and Physics Library | Expat and Zlib | 2011, Ole Kniemeyer, MAXON, www.maxon.net; 2003-2008, Erwin Coumans; 2007, Starbreeze Studios |
| Linux AppStream Metadata File | CC0-1.0 | 2017-2022, Rémi Verschelde |
| Godot Engine logo | CC-BY-4.0 | 2017, Andrea Calabró |
| Betsy | Expat | 2020-2022, Matias N. Goldberg |
| Chipmunk2D Joint Constraints | Expat | 2007, Scott Lembcke |
| Open Dynamics Engine | BSD-3-clause | 2001-2003, Russell L. Smith, Alen Ladavac, Nguyen Binh |
| Jolt Physics | Expat | 2021, Jorrit Rouwe |
| Joint Non-Local Means (JNLM) denoiser | Expat | 2020, Manuel Prandini |
| The Android Open Source Project | Apache-2.0 | 2008-2016, The Android Open Source Project; 2002, Google, Inc. |
| ProcessPhoenix | Apache-2.0 | 2015, Jake Wharton |
| Robert Penner's Easing Functions | Expat | 2001, Robert Penner |
| NVidia's FXAA 3.11, simplified by Simon Rodriguez | BSD-3-clause and Expat | 2014-2015, NVIDIA CORPORATION; 2017 Simon Rodriguez |
| Intel ASSAO and related files | Expat | 2016, Intel Corporation |
| Temporal Anti-Aliasing resolve implementation | Expat | 2016, Panos Karabelas |
| Subpixel Morphological Antialiasing | Expat | 2013, Jorge Jimenez; 2013, Jose I. Echevarria; 2013, Belen Masia; 2013, Fernando Navarro; 2013, Diego Gutierrez |
| AccessKit | Expat | 2023, The AccessKit Authors. |
| AMD FidelityFX Super Resolution | Expat | 2021, Advanced Micro Devices, Inc. |
| AMD FidelityFX Super Resolution 2 | Expat | 2022-2023, Advanced Micro Devices, Inc. |
| ANGLE | BSD-3-clause | 2018, The ANGLE Project Authors. |
| Arm ASTC Encoder | Apache-2.0 | 2011-2025, Arm Limited |
| Basis Universal | Apache-2.0 | 2019-2025, Binomial LLC. |
| Brotli | Expat | 2009, 2010, 2013-2016 by the Brotli Authors. |
| CA certificates | MPL-2.0 | Mozilla Contributors |
| Clipper2 | BSL-1.0 | 2010-2025, Angus Johnson |
| Convection Texture Tools Stand-Alone Kernels | Expat | 2018, Eric Lasota; 2018, Microsoft Corp. |
| D3D12 Memory Allocator | Expat | 2019-2022 Advanced Micro Devices, Inc. |
| DirectX Headers | Expat | Microsoft Corporation |
| doctest | Expat | 2016-2023, Viktor Kirilov |
| dr_libs | Unlicense or MIT-0 | 2020, David Reid |
| Embree | Apache-2.0 | 2009-2021 Intel Corporation |
| ENet | Expat | 2002-2024, Lee Salzman |
| etcpak | BSD-3-clause | 2013-2022, Bartosz Taudul |
| DroidSans font | Apache-2.0 | 2008, The Android Open Source Project |
| Inter font | OFL-1.1 | 2016, The Inter Project Authors |
| JetBrains Mono font | OFL-1.1 | 2020, JetBrains s.r.o. |
| Noto Sans font | OFL-1.1 | 2012, Google Inc. |
| Open Sans font | OFL-1.1 | 2020, The Open Sans Project Authors |
| Vazirmatn font | OFL-1.1 | 2015, The Vazirmatn Project Authors. |
| The FreeType Project | FTL | 1996-2025, David Turner, Robert Wilhelm, and Werner Lemberg. |
| GamepadMotionHelpers | Expat | 2020-2023, Julian "Jibb" Smart |
| glad | CC0-1.0 and Apache-2.0 | 2013-2022, David Herberth; 2013-2020, The Khronos Group Inc. |
| glslang | glslang | 2015-2020, Google, Inc.; 2014-2020, The Khronos Group Inc; 2002, NVIDIA Corporation. |
| Graphite engine | Expat | 2010, SIL International |
| Grisu2 float serialization algorithm | Expat and Apache-2.0 | 2009, Florian Loitsch; 2018-2023, The simdjson authors |
| HarfBuzz text shaping library | HarfBuzz | 2010-2022, Google, Inc.; 2015-2020, Ebrahim Byagowi; 2019,2020, Facebook, Inc.; 2012, 2015, Mozilla Foundation; 2011, Codethink Limited; 2008, 2010, Nokia Corporation and/or its subsidiary(-ies); 2009, Keith Stribley; 2011, Martin Hosken and SIL International; 2007, Chris Wilson; 2005-2006, 2020-2023, Behdad Esfahbod; 2004, 2007-2010, 2013, 2021-2023, Red Hat, Inc.; 1998-2005, David Turner and Werner Lemberg; 2016, Igalia, S.L.; 2022, Matthias Clasen; 2018, 2021, Khaled Hosny; 2018-2020, Adobe, Inc.; 2013-2015, Alexei Podtelezhnikov |
| International Components for Unicode | Unicode | 2016-2024, Unicode, Inc. |
| libbacktrace | BSD-3-clause | 2012-2021, Free Software Foundation, Inc. |
| libjpeg-turbo | BSD-3-clause and IJG | 2009-2025, D. R. Commander; 2015, Viktor Szathmáry.; 1991-2020, Thomas G. Lane, Guido Vollbeding |
| KTX | Apache-2.0 | 2013-2020, Mark Callow; 2010-2020 The Khronos Group, Inc. |
| OggVorbis | BSD-3-clause | 2002, Xiph.org Foundation; 2002-2015, Xiph.org Foundation |
| libpng | Zlib | 1995-2026, The PNG Reference Library Authors.; 2018-2026, Cosmin Truta.; 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson.; 1996-1997, Andreas Dilger.; 1995-1996, Guy Eric Schalnat, Group 42, Inc. |
| OggTheora | BSD-3-clause | 2002-2009, Xiph.org Foundation |
| WebP codec | BSD-3-clause | 2010, Google Inc. |
| Manifold | Apache-2.0 | 2020-2025, The Manifold Authors |
| Mbed TLS | Apache-2.0 | The Mbed TLS Contributors |
| meshoptimizer | Expat | 2016-2026, Arseny Kapoulkine |
| metal-cpp | Apache-2.0 | 2024, Apple Inc. |
| mingw-std-threads | BSD-2-clause | 2016, Mega Limited |
| MiniUPnP Project | BSD-3-clause | 2005-2025, Thomas Bernard |
| MiniZip | Zlib | 1998-2026, Gilles Vollant; 2007-2008, Even Rouault; 2009-2010, Mathias Svensson |
| bcdec | Expat | 2022, Sergii Kudlai |
| Fast Filtering of Reflection Probes | Expat | 2016, Activision Publishing, Inc. |
| FastLZ | Expat | 2005-2020, Ariya Hidayat |
| FastNoise Lite | Expat | 2023, Jordan Peck and contributors |
| libjingle | BSD-3-clause | 2012-2013, Google Inc. |
| Tangent Space Normal Maps implementation | Zlib | 2011, Morten S. Mikkelsen |
| NVIDIA NVAPI (minimal excerpt) | Expat | 2019-2022, NVIDIA Corporation |
| OK Lab color space | Expat | 2021, Björn Ottosson |
| Minimal PCG32 implementation | Apache-2.0 | 2014, M.E. O'Neill |
| PolyPartition / Triangulator | Expat | 2011-2021, Ivan Fratric and contributors |
| Quite OK Audio Format | Expat | 2023, Dominic Szablewski |
| r128 library | Unlicense | Alan Hickman |
| SMAZ | BSD-3-clause | 2006-2009, Salvatore Sanfilippo |
| SMOL-V | Unlicense or Expat | 2016-2024, Aras Pranckevicius |
| stb libraries | Unlicense or Expat | Sean Barrett |
| YUV2RGB | BSD-2-clause | 2008-2011, Robin Watts |
| Multi-channel signed distance field generator | Expat | 2014-2025, Viktor Chlumsky |
| OpenXR Loader | Apache-2.0 | 2020-2025, The Khronos Group Inc. |
| PCRE2 | BSD-3-clause | 1997-2024, University of Cambridge; 2009-2024, Zoltan Herczeg |
| Recast | Zlib | 2009, Mikko Mononen |
| RVO2 | Apache-2.0 | 2016, University of North Carolina at Chapel Hill |
| SDL | Zlib | 1997-2025, Sam Lantinga |
| hidapi | BSD-3-clause | 2010, Alan Ott, Signal 11 Software |
| SPIRV-Cross | Apache-2.0 or Expat | 2015-2021, Arm Limited |
| SPIRV-Headers | Expat | 2015-2024, The Khronos Group Inc. |
| SPIRV-Reflect | Apache-2.0 | 2017-2022, Google Inc. |
| Swappy | Apache-2.0 | 2019, The Android Open Source Project |
| ThorVG | Expat | 2020-2026, The ThorVG Project |
| TinyEXR | BSD-3-clause | 2014-2021, Syoyo Fujita; 2002, Industrial Light & Magic, a division of Lucas Digital Ltd. LLC |
| ufbx | Expat | 2020, Samuli Raivio |
| V-HACD | BSD-3-clause | 2011, Khaled Mamou; 2003-2009, Erwin Coumans |
| volk | Expat | 2018-2025, Arseny Kapoulkine |
| Vulkan Headers | Apache-2.0 | 2015-2025, The Khronos Group Inc.; 2015-2025, Valve Corporation; 2015-2025, LunarG, Inc. |
| Vulkan Memory Allocator | Expat | 2017-2025, Advanced Micro Devices, Inc. |
| Wayland core protocol | Expat | 2008-2012, Kristian Høgsberg; 2010-2012, Intel Corporation; 2011, Benjamin Franzke; 2012, Collabora, Ltd. |
| Wayland protocols | Expat | 2008-2013, Kristian Høgsberg; 2010-2013, Intel Corporation; 2013, Rafael Antognolli; 2013, Jasper St. Pierre; 2014, Jonas Ådahl; 2014, Jason Ekstrand; 2014-2015, Collabora, Ltd.; 2015, Red Hat Inc. |
| Mesa Wayland protocols | X11 | 2008-2011, Kristian Høgsberg; 2010-2011, Intel Corporation |
| Wslay | Expat | 2011, 2012, 2015, Tatsuhiro Tsujikawa |
| xatlas | Expat | 2018-2020, Jonathan Young; 2013, Thekla, Inc; 2006, NVIDIA Corporation, Ignacio Castano |
| zlib | Zlib | 1995-2026, Jean-loup Gailly and Mark Adler |
| Zstandard | BSD-3-clause | Meta Platforms, Inc. and affiliates. |

## 3. 表示義務で気をつけること

- **MIT・BSD・Zlib・Apache-2.0・OFL・FTL など**: どれも著作権表示とライセンス本文を配布物に入れれば足りる。
  クレジット画面（ゲーム内）と、配布フォルダのテキストファイル（例: `THIRD_PARTY_LICENSES.txt`）の両方に置くのが
  確実（KAN-45）
- **FreeType（FTL）**: 文書のどこかに「Portions of this software are copyright © <年> The FreeType Project
  (www.freetype.org). All rights reserved.」の一文を入れることが求められている
- **Apache-2.0（Mbed TLS ほか）**: 元のソフトウェアに NOTICE ファイルがある場合は、その内容も表示する。
  Godot の `get_license_info()` の Apache-2.0 本文で足りるかは KAN-45 で確認すること
- **Godot のロゴ（CC-BY-4.0）**: `project.godot` に `boot_splash` の設定が無いので、起動時のスプラッシュは
  Godot の既定のものになる。ロゴを表示するなら CC-BY-4.0 のクレジット（§2 の表の「Godot Engine logo」）が要る
- **EOS SDK**: OSS のライセンス本文ではなく、EULA の免責条項とストアの免責文で義務を果たす（§1）

## 4. 素材（音源・3D モデル・テクスチャ）

外部から取り込んだ素材は無い（2026-10-16 に確認）。

| 素材 | 出所 | 確かめたこと |
|---|---|---|
| 3D モデル（`assets/character/*.glb`、`assets/character/hats/*.glb`、`assets/character/outfits/*.glb`、`assets/gimmicks/*.glb`、`assets/props/*.glb`） | `tools/blender/build_*.py` が Blender の中で一から組み立てて書き出したもの | スクリプトに外部ファイルの読み込み（`images.load` / `import_scene` / `wm.append` / `wm.link`）が無い |
| テクスチャ（`assets/character/outfits/*.png`） | `build_overalls.py` / `build_shadow_ninja.py` が `bpy.data.images.new` で描いたもの | 同上 |
| BGM（`assets/audio/bgm/title_bgm.ogg`） | 生成 AI（Gemini）で作ったもの。サードパーティのライセンスではなく、生成 AI の利用規約と itch.io の AI 開示の対象 | `docs/AI_GENERATED_ASSETS.md`（KAN-46） |
| フォント | §1 の M PLUS Rounded 1c | — |

衣装の元絵（`tools/blender/references/*.png`）や主人公の参考画像（`tools/blender/reference.png`）は
`tools/blender/` にあるだけで配布物には入らない（KAN-30 で pck に入らないことを確認済み）。出所は
`docs/AI_GENERATED_ASSETS.md` を参照。
