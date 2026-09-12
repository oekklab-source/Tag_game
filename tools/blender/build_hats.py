"""帽子(頭部装備)パーツを手続き的に組み立て、スキニング無しの単一メッシュ glb として
個別に書き出すビルドスクリプト。fallguy.glb 本体は一切再エクスポートしない。

    blender -b -P tools/blender/build_hats.py

出力:
    tools/blender/hats.blend                 編集元（.gdignore で Godot のインポート対象外）
    assets/character/hats/hat_party.glb      パーティハット
    assets/character/hats/hat_cap.glb        キャップ
    assets/character/hats/hat_propeller.glb  プロペラ帽
    assets/character/hats/hat_wizard.glb     まほうつかいの帽子
    assets/character/hats/hat_crown.glb      王冠
    assets/character/hats/hat_cat_ears.glb   ネコミミビーニー

帽子は Chest ボーンへ BoneAttachment3D 経由で剛体アタッチする前提（scenes/humanoid.gd
apply_hat() 参照）なので、頂点グループ（スキニング）は付けない。原点(0,0,0)がだいたい
頭頂のすぐ上に来るようモデリングしてあるが、実際のオフセットは Godot エディタ上で
仮置きして目視調整し autoload/hat_catalog.gd に転記すること
（Blender と glTF でボーン軸の向きが変わるため机上計算では決められない）。

新しい帽子を追加する際は HAT_BUILDERS に組み立て関数を1つ増やすだけでよい。

汎用ジオメトリヘルパ(lathe/bake/cleanup/cone/ball/superellipse)は
tools/blender/build_fallguy.py と重複しているが、検証済みの本体パイプラインに
影響を与えないよう意図的に複製してある。3本目のパーツ系ビルドスクリプトが
必要になったら共通モジュールへの切り出しを検討すること。
"""

import math
import os

import bmesh
import bpy

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "hats.blend")
OUT_DIR = os.path.join(PROJECT, "assets", "character", "hats")


# =====================================================================
# 汎用ジオメトリヘルパ（build_fallguy.py と同等）
# =====================================================================

def make_mat(name, rgb, emission=0.0, roughness=0.45, metallic=0.0):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Emission Strength"].default_value = emission
    mat.diffuse_color = (*rgb, 1.0)
    return mat


def lathe(name, profile, segments=24):
    """(高さ, 半径) の並びを Z 軸まわりの回転体にする。半径0の点は極として1頂点に潰す。"""
    bm = bmesh.new()
    rings = []
    for h, r in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, h))])
        else:
            rings.append([bm.verts.new((math.cos(a) * r, math.sin(a) * r, h))
                          for a in (2.0 * math.pi * i / segments for i in range(segments))])
    for lower, upper in zip(rings, rings[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            if len(lower) == 1:
                bm.faces.new((lower[0], upper[j], upper[i]))
            elif len(upper) == 1:
                bm.faces.new((lower[j], lower[i], upper[0]))
            else:
                bm.faces.new((lower[i], lower[j], upper[j], upper[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for poly in mesh.polygons:
        poly.use_smooth = True
    return obj


def bake(obj, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    """変換をメッシュに焼き込み、オブジェクト変換を単位に戻す。連続適用で合成できる。"""
    obj.location, obj.rotation_euler, obj.scale = loc, rot, scale
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def join_into(target, others):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in others:
        obj.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()
    return target


def cleanup(obj):
    """ブーリアンや結合で出た重複頂点・不正な面を掃除する（glTF の検証警告対策）。"""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.validate(verbose=False)
    obj.data.update()
    return obj


def superellipse(z0, z1, rmax, n_low, n_up, rows=20):
    pts = []
    for i in range(rows + 1):
        t = 0.5 - 0.5 * math.cos(math.pi * i / rows)
        u = 2.0 * t - 1.0
        n = n_low if u < 0.0 else n_up
        pts.append((z0 + (z1 - z0) * t, max(rmax * (1.0 - abs(u) ** n) ** (1.0 / n), 0.0)))
    pts[0], pts[-1] = (z0, 0.0), (z1, 0.0)
    return pts


def cone(name, base_r, height, segments=10, rows=5, sink=0.4):
    """トゲ用の円錐（ローカル +Z が先端方向）。根元を体内へ sink ぶん埋めておく。"""
    pts = [(-height * sink, 0.0), (-height * sink * 0.55, base_r * 0.9), (0.0, base_r)]
    pts += [(height * i / rows, base_r * (1.0 - i / rows) ** 0.8) for i in range(1, rows)]
    pts.append((height, 0.0))
    return lathe(name, pts, segments)


def ball(name, center, scale, rot=(0, 0, 0), segments=16):
    sphere = superellipse(-1.0, 1.0, 1.0, 2.0, 2.0, rows=12)
    return bake(lathe(name, sphere, segments), loc=center, rot=rot, scale=scale)


# =====================================================================
# 帽子ビルダー
# =====================================================================

def build_party_hat():
    """円錐 + 天辺のポンポン。build_fallguy.py の背びれ(cone)と同じ手法。"""
    cone_obj = cone("PartyCone", base_r=0.20, height=0.34, segments=20, sink=0.05)
    cone_obj.data.materials.append(make_mat("PartyRed", (0.85, 0.25, 0.30)))
    pom = ball("PartyPom", (0.0, 0.0, 0.35), (0.050, 0.050, 0.050))
    pom.data.materials.append(make_mat("PartyPomWhite", (0.95, 0.95, 0.95)))
    join_into(cone_obj, [pom])
    cleanup(cone_obj)
    cone_obj.name = "HatParty"
    return cone_obj


def build_cap():
    """半球ドーム + 前方だけに張り出す扇形のブリム。"""
    dome = ball("CapDome", (0.0, 0.0, 0.10), (0.205, 0.205, 0.135))
    dome.data.materials.append(make_mat("CapMain", (0.25, 0.45, 0.85)))

    bm = bmesh.new()
    center = bm.verts.new((0.0, -0.15, 0.02))
    rim = [bm.verts.new((math.cos(a) * 0.16, -0.15 - math.sin(a) * 0.12, 0.02))
           for a in (math.pi * i / 12 for i in range(13))]
    for i in range(len(rim) - 1):
        bm.faces.new((center, rim[i], rim[i + 1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("CapBrim")
    bm.to_mesh(mesh)
    bm.free()
    brim = bpy.data.objects.new("CapBrim", mesh)
    bpy.context.collection.objects.link(brim)
    for poly in mesh.polygons:
        poly.use_smooth = True
    brim.data.materials.append(make_mat("CapBrimDark", (0.12, 0.12, 0.15)))

    join_into(dome, [brim])
    cleanup(dome)
    dome.name = "HatCap"
    return dome


def build_propeller_hat():
    """半球ドーム + 軸 + 十字プロペラ。"""
    dome = ball("PropDome", (0.0, 0.0, 0.09), (0.205, 0.205, 0.115))
    dome.data.materials.append(make_mat("PropMain", (0.95, 0.75, 0.20)))

    shaft = cone("PropShaft", base_r=0.014, height=0.10, segments=8, sink=0.3)
    bake(shaft, loc=(0.0, 0.0, 0.19))
    shaft.data.materials.append(make_mat("PropShaftGray", (0.5, 0.5, 0.55)))

    blade_mat = make_mat("PropBlade", (0.90, 0.30, 0.35))
    blades = []
    for i, rot_z in enumerate((0.0, math.pi / 2.0)):
        bpy.ops.mesh.primitive_plane_add(size=0.22)
        blade = bpy.context.object
        blade.name = "PropBlade%d" % i
        blade.data.materials.append(blade_mat)
        bake(blade, loc=(0.0, 0.0, 0.30), rot=(0.0, 0.0, rot_z), scale=(1.0, 0.22, 1.0))
        blades.append(blade)

    join_into(dome, [shaft] + blades)
    cleanup(dome)
    dome.name = "HatPropeller"
    return dome


def build_wizard_hat():
    """つばの広い魔法使いの帽子 + 先端に光る飾り(球体)。"""
    # ゆるやかにカーブして先端が細くなる円錐のプロファイル
    pts = [
        (0.00, 0.00),  # 底面の中心(穴を塞ぐ)
        (0.00, 0.28),  # つばの外縁
        (0.01, 0.28),  # つばの厚み
        (0.015, 0.15), # つばの根本(少し持ち上がる)
        (0.10, 0.13),  # 円錐の中間1
        (0.20, 0.08),  # 円錐の中間2
        (0.35, 0.00)   # 先端
    ]
    hat = lathe("WizardBase", pts, segments=24)
    hat.data.materials.append(make_mat("WizardPurple", (0.15, 0.05, 0.25)))

    # 先端の星(丸っこい球体として表現)
    tip = ball("WizardTip", (0.0, 0.0, 0.35), (0.04, 0.04, 0.04))
    tip.data.materials.append(make_mat("WizardStar", (0.95, 0.85, 0.15), emission=0.8))

    join_into(hat, [tip])
    cleanup(hat)
    hat.name = "HatWizard"
    return hat


def build_crown():
    """円柱状の土台 + 周囲に複数の円錐と光る宝石を配置した王冠。"""
    # 王冠の土台部分（中が空洞にならないように厚みを持たせる）
    pts = [
        (0.00, 0.00), # 外部の底中心
        (0.00, 0.16), # 底の外縁
        (0.08, 0.18), # 上に広がる外側
        (0.08, 0.16), # 内側へ折り返し
        (0.01, 0.14), # 内側の底付近
        (0.01, 0.00), # 内部の底中心
    ]
    crown = lathe("CrownBase", pts, segments=24)
    mat_gold = make_mat("CrownGold", (0.90, 0.70, 0.10), roughness=0.3, metallic=0.8)
    crown.data.materials.append(mat_gold)

    spikes = []
    spike_count = 6
    for i in range(spike_count):
        a = 2.0 * math.pi * i / spike_count

        # トゲ(円錐)
        spike = cone(f"CrownSpike{i}", base_r=0.03, height=0.08, segments=8, sink=0.2)
        spike.data.materials.append(mat_gold)
        # 縁の傾きに合わせて外側に傾ける(Y軸まわり0.2)、さらに円周上に配置(Z軸まわりa)
        bake(spike,
             loc=(math.cos(a) * 0.17, math.sin(a) * 0.17, 0.07),
             rot=(0.0, 0.2, a))

        # トゲの先端に乗せる宝石(球体)
        gem = ball(f"CrownGem{i}", (0.0, 0.0, 0.08), (0.015, 0.015, 0.015))
        mat_gem = make_mat("CrownGemRed", (0.90, 0.10, 0.20), emission=1.0)
        gem.data.materials.append(mat_gem)
        # トゲと全く同じ変換を適用することで、ローカルZ(0.08)にある球体が先端へ正確に配置される
        bake(gem,
             loc=(math.cos(a) * 0.17, math.sin(a) * 0.17, 0.07),
             rot=(0.0, 0.2, a))

        spikes.extend([spike, gem])

    join_into(crown, spikes)
    cleanup(crown)
    crown.name = "HatCrown"
    return crown


def build_cat_ears():
    """ドーム型のニット帽ベース + ピンと立った平たい三角形のネコミミ。"""
    # ドーム型のベース(キャップやプロペラ帽と同じ手法)
    dome = ball("CatDome", (0.0, 0.0, 0.08), (0.21, 0.21, 0.14))
    mat_main = make_mat("CatMain", (0.15, 0.15, 0.15)) # 黒猫風
    dome.data.materials.append(mat_main)

    ears = []
    mat_inner = make_mat("CatInner", (0.85, 0.35, 0.45)) # 耳の内側(ピンク)

    for i, sign in enumerate([-1.0, 1.0]):
        # 外側の耳(黒)
        ear = cone(f"CatEarOuter{i}", base_r=0.07, height=0.12, segments=12, sink=0.2)
        ear.data.materials.append(mat_main)
        # Y軸方向にスケールを0.5に潰すことで、ネコミミっぽく平たくする
        bake(ear, loc=(0.12 * sign, 0.0, 0.16), rot=(0.0, 0.3 * sign, 0.0), scale=(1.0, 0.5, 1.0))

        # 内側の耳(ピンク)。少し小さくし、Y方向(前)にずらして重ねる
        inner = cone(f"CatEarInner{i}", base_r=0.04, height=0.08, segments=10, sink=0.1)
        inner.data.materials.append(mat_inner)
        bake(inner, loc=(0.12 * sign, -0.02, 0.17), rot=(0.0, 0.3 * sign, 0.0), scale=(1.0, 0.4, 1.0))

        ears.extend([ear, inner])

    join_into(dome, ears)
    cleanup(dome)
    dome.name = "HatCatEars"
    return dome


HAT_BUILDERS = {
    "hat_party": build_party_hat,
    "hat_cap": build_cap,
    "hat_propeller": build_propeller_hat,
    "hat_wizard": build_wizard_hat,
    "hat_crown": build_crown,
    "hat_cat_ears": build_cat_ears,
}


def export_single(obj, filename):
    path = os.path.join(OUT_DIR, filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', export_yup=True, export_apply=True,
        export_skins=False, export_animations=False, export_materials='EXPORT',
        export_texcoords=False, use_selection=True)
    print("export :", path, os.path.getsize(path), "bytes")


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30
    built = []
    for stem, builder in HAT_BUILDERS.items():
        obj = builder()
        export_single(obj, stem + ".glb")
        built.append(obj)
    # .blend 内で重ならないよう並べる（書き出し後なので glb の座標には影響しない）
    for i, obj in enumerate(built):
        obj.location.x = i * 0.6
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("saved  :", BLEND_PATH)


main()
