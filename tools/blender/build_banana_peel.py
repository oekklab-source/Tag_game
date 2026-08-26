"""Build the selected low-poly banana-peel trap and export it for Godot.

Run through Blender so the editable .blend and the game-ready GLB always come
from the same source geometry.
"""

import math
import os

import bpy
from mathutils import Vector


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(PROJECT, "tools", "blender", "banana_peel.blend")
GLB_PATH = os.path.join(PROJECT, "assets", "gimmicks", "banana_peel.glb")

PEEL_YELLOW = (1.0, 0.72, 0.05, 1.0)
INNER_YELLOW = (1.0, 0.87, 0.28, 1.0)
STEM_BROWN = (0.35, 0.16, 0.06, 1.0)


def make_material(name, color, roughness=0.48):
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    shader = next(
        node for node in material.node_tree.nodes
        if node.type == "BSDF_PRINCIPLED"
    )
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    material.diffuse_color = color
    return material


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in list(bpy.data.collections):
        if collection.users == 0:
            bpy.data.collections.remove(collection)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def add_bevel(obj, width):
    modifier = obj.modifiers.new("Soft low-poly edges", "BEVEL")
    modifier.width = width
    modifier.segments = 1
    modifier.limit_method = "ANGLE"


def make_peel_flap(name, angle, length_scale, root, peel_material, inner_material):
    """Create one thick, curved peel flap as a small low-poly ribbon mesh."""
    radial = Vector((math.cos(angle), math.sin(angle), 0.0))
    side = Vector((-math.sin(angle), math.cos(angle), 0.0))
    profile = (
        (0.12, 0.76, 0.16),
        (0.24, 0.64, 0.25),
        (0.46 * length_scale, 0.40, 0.33),
        (0.73 * length_scale, 0.18, 0.32),
        (0.96 * length_scale, 0.09, 0.22),
    )
    centers = [radial * radius + Vector((0.0, 0.0, height))
               for radius, height, _width in profile]
    thickness = 0.075
    vertices = []
    for index, center in enumerate(centers):
        before = centers[max(index - 1, 0)]
        after = centers[min(index + 1, len(centers) - 1)]
        tangent = (after - before).normalized()
        normal = side.cross(tangent).normalized()
        if normal.z < 0.0:
            normal.negate()
        half_width = profile[index][2] * 0.5
        vertices.extend((
            center - side * half_width + normal * (thickness * 0.5),
            center + side * half_width + normal * (thickness * 0.5),
            center + side * half_width - normal * (thickness * 0.5),
            center - side * half_width - normal * (thickness * 0.5),
        ))

    faces = []
    material_indices = []
    for index in range(len(centers) - 1):
        a, b = index * 4, (index + 1) * 4
        faces.extend(((a, a + 1, b + 1, b), (a + 3, b + 3, b + 2, a + 2),
                      (a, b, b + 3, a + 3), (a + 1, a + 2, b + 2, b + 1)))
        # The upward-facing surface is the peel exterior. Keep it saturated
        # yellow; the pale yellow is reserved for the downward-facing inside.
        material_indices.extend((0, 1, 0, 0))
    faces.extend(((0, 3, 2, 1), (len(vertices) - 4, len(vertices) - 3,
                  len(vertices) - 2, len(vertices) - 1)))
    material_indices.extend((0, 0))

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.materials.append(peel_material)
    mesh.materials.append(inner_material)
    for polygon, material_index in zip(mesh.polygons, material_indices):
        polygon.material_index = material_index
        polygon.use_smooth = False
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    add_bevel(obj, 0.025)
    return obj


def add_cone(name, vertices, radius_bottom, radius_top, depth, z, material, root):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius_bottom,
        radius2=radius_top,
        depth=depth,
        location=(0.0, 0.0, z),
    )
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(material)
    obj.parent = root
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    add_bevel(obj, 0.015)
    return obj


def build():
    clear_scene()
    peel_material = make_material("BananaPeelOuter", PEEL_YELLOW)
    inner_material = make_material("BananaPeelInner", INNER_YELLOW)
    stem_material = make_material("BananaPeelStem", STEM_BROWN, roughness=0.62)

    root = bpy.data.objects.new("BananaPeel", None)
    bpy.context.collection.objects.link(root)
    root.scale.z = 0.5

    # Three broad flaps form the selected number-1 silhouette: one forward,
    # two splayed to either side. The center remains visibly empty.
    make_peel_flap("PeelFront", math.radians(-90.0), 1.06, root,
                   peel_material, inner_material)
    make_peel_flap("PeelLeft", math.radians(150.0), 0.94, root,
                   peel_material, inner_material)
    make_peel_flap("PeelRight", math.radians(30.0), 0.94, root,
                   peel_material, inner_material)
    add_cone("PeelCollar", 8, 0.20, 0.13, 0.16, 0.78, peel_material, root)
    add_cone("Stem", 8, 0.12, 0.09, 0.18, 0.95, stem_material, root)

    bpy.context.view_layer.update()
    return root


def export():
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        export_apply=True,
        export_materials="EXPORT",
        export_texcoords=False,
        export_cameras=False,
        export_lights=False,
        use_visible=False,
        use_selection=False,
    )


def main():
    root = build()
    export()
    result = {
        "root": root.name,
        "objects": [child.name for child in root.children],
        "blend_path": BLEND_PATH,
        "glb_path": GLB_PATH,
        "vertex_count": sum(len(child.data.vertices) for child in root.children
                            if child.type == "MESH"),
        "polygon_count": sum(len(child.data.polygons) for child in root.children
                             if child.type == "MESH"),
    }
    return result


result = main()
