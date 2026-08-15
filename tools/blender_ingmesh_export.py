import argparse
import math
import os
import struct
import sys
import tempfile

import bmesh
import bpy

MAGIC = b"INGMESH1"
VERSION = 1
MAX_MESHES = 256
MAX_VERTICES = 16384
MAX_INDICES = 49152
EXPECTED_OBJECTS = {
    1: "Conifer_A",
    2: "Conifer_B",
    3: "Broadleaf",
    4: "Grass_Upright",
    5: "Grass_Crossed",
    6: "Grass_Reed",
    7: "Boulder_A",
    8: "Boulder_B",
    9: "Boulder_C",
    10: "Rock_A",
    11: "Rock_B",
}
MATERIAL_SCALARS = {
    "TF_Bark": 0.0,
    "TF_Foliage": 1.0,
    "TF_Grass": 1.5,
    "TF_Rock": 0.0,
    "TF_Dry": 0.0,
}
GROUND_TOLERANCE = 0.001


def fail(message):
    raise ValueError(message)


def canonicalize(value):
    value = float(value)
    if not math.isfinite(value):
        fail("mesh contains a non-finite number")
    return 0.0 if value == 0.0 else value


def convert_vector(value):
    return canonicalize(value.y), canonicalize(-value.x), canonicalize(value.z)


def parse_arguments():
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args(arguments)


def material_scalar(obj, polygon):
    if polygon.material_index >= len(obj.material_slots):
        fail(f"{obj.name}: polygon has no material")
    material = obj.material_slots[polygon.material_index].material
    if material is None or material.name not in MATERIAL_SCALARS:
        name = "<none>" if material is None else material.name
        fail(f"{obj.name}: unsupported material {name!r}")
    return MATERIAL_SCALARS[material.name]


def evaluated_mesh(obj):
    dependency_graph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(dependency_graph)
    mesh = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=dependency_graph)
    if mesh is None:
        fail(f"{obj.name}: cannot evaluate mesh")
    triangulated = bmesh.new()
    triangulated.from_mesh(mesh)
    bmesh.ops.triangulate(triangulated, faces=triangulated.faces[:])
    triangulated.to_mesh(mesh)
    triangulated.free()
    mesh.calc_loop_triangles()
    return evaluated, mesh


def mesh_payload(obj):
    evaluated, mesh = evaluated_mesh(obj)
    try:
        if not mesh.uv_layers.active:
            fail(f"{obj.name}: active UV layer is required")
        uv_data = mesh.uv_layers.active.data
        vertices = []
        indices = []
        unique = {}
        for triangle in mesh.loop_triangles:
            polygon = mesh.polygons[triangle.polygon_index]
            scalar = material_scalar(obj, polygon)
            for loop_index in triangle.loops:
                loop = mesh.loops[loop_index]
                position = convert_vector(mesh.vertices[loop.vertex_index].co)
                normal = convert_vector(loop.normal)
                uv = tuple(canonicalize(value) for value in uv_data[loop_index].uv)
                key = position + normal + (scalar,) + uv
                index = unique.get(key)
                if index is None:
                    index = len(vertices)
                    unique[key] = index
                    vertices.append(key)
                indices.append(index)
        if not vertices or not indices or len(indices) % 3:
            fail(f"{obj.name}: mesh must contain indexed triangles")
        minimum = tuple(min(vertex[axis] for vertex in vertices) for axis in range(3))
        maximum = tuple(max(vertex[axis] for vertex in vertices) for axis in range(3))
        if abs(minimum[2]) > GROUND_TOLERANCE:
            fail(f"{obj.name}: minimum Z must be ground level, got {minimum[2]}")
        return vertices, indices, minimum, maximum
    finally:
        evaluated.to_mesh_clear()


def collect_meshes():
    meshes = []
    seen = set()
    for obj in bpy.data.objects:
        if obj.type != "MESH" or "ingot_mesh_id" not in obj:
            continue
        mesh_id = obj["ingot_mesh_id"]
        if isinstance(mesh_id, bool) or not isinstance(mesh_id, int):
            fail(f"{obj.name}: ingot_mesh_id must be an integer")
        if mesh_id not in EXPECTED_OBJECTS or obj.name != EXPECTED_OBJECTS[mesh_id]:
            fail(f"{obj.name}: unexpected object name or mesh ID {mesh_id}")
        if mesh_id in seen:
            fail(f"duplicate ingot_mesh_id {mesh_id}")
        if any(abs(value - 1.0) > 0.000001 for value in obj.scale):
            fail(f"{obj.name}: apply object scale before export")
        if any(abs(value) > 0.000001 for value in obj.location):
            fail(f"{obj.name}: apply object location before export")
        if any(abs(value) > 0.000001 for value in obj.rotation_euler):
            fail(f"{obj.name}: apply object rotation before export")
        seen.add(mesh_id)
        meshes.append((mesh_id, *mesh_payload(obj)))
    if seen != set(EXPECTED_OBJECTS):
        missing = sorted(set(EXPECTED_OBJECTS) - seen)
        fail(f"missing required mesh IDs: {missing}")
    meshes.sort(key=lambda item: item[0])
    return meshes


def serialize(meshes):
    if not meshes or len(meshes) > MAX_MESHES:
        fail("mesh count exceeds the cooked format limit")
    vertex_count = sum(len(mesh[1]) for mesh in meshes)
    index_count = sum(len(mesh[2]) for mesh in meshes)
    if vertex_count > MAX_VERTICES or index_count > MAX_INDICES:
        fail(f"asset budget exceeded: {vertex_count} vertices, {index_count} indices")
    header = struct.pack("<8sIIII", MAGIC, VERSION, len(meshes), vertex_count, index_count)
    records = bytearray()
    vertex_bytes = bytearray()
    index_bytes = bytearray()
    first_vertex = 0
    first_index = 0
    for mesh_id, vertices, indices, minimum, maximum in meshes:
        records.extend(
            struct.pack(
                "<IIIIIffffff",
                mesh_id,
                first_vertex,
                len(vertices),
                first_index,
                len(indices),
                *minimum,
                *maximum,
            )
        )
        for vertex in vertices:
            vertex_bytes.extend(struct.pack("<fffffffff", *vertex))
        for index in indices:
            index_bytes.extend(struct.pack("<I", index))
        first_vertex += len(vertices)
        first_index += len(indices)
    return header + records + vertex_bytes + index_bytes


def write_output(path, data, check):
    if check:
        try:
            with open(path, "rb") as existing:
                current = existing.read()
        except OSError as error:
            fail(f"cannot read cooked output for --check: {error}")
        if current != data:
            fail(f"{path} is stale; regenerate it without --check")
        return
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ingmesh-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def export_bundle(input_path, output_path, check):
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(input_path))
    write_output(output_path, serialize(collect_meshes()), check)


def main():
    try:
        options = parse_arguments()
        export_bundle(options.input, options.output, options.check)
        return 0
    except (OSError, ValueError) as error:
        print(f"blender_ingmesh_export: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
