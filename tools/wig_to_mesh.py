"""Converts the supplied wig GLB into the compact mesh the app loads.

Why this exists rather than a USDZ conversion: RealityKit takes a
`MeshDescriptor` directly, which is already how `CylinderMesh` builds the
rollers, so the whole USD pipeline can be skipped. That matters because Apple
retired `usdzconvert` and Google's `usd_from_gltf` has to be built from source
— neither is something a CI runner should depend on.

What it does, and why:

* **Drops the roller assemblies.** Nine of them, 244,800 of the file's 640,144
  triangles. The app builds its own rollers with generated normal and roughness
  maps; the ones in the file are flat colour with no surface detail at all.
* **Drops whole strands, never vertices.** Vertex clustering would merge
  neighbouring strands into blobs, which is exactly the detail worth keeping.
  Connected components are strands, so thinning is a matter of choosing which
  ones survive — deterministically, so the output is reproducible.
* **Keeps the small meshes whole.** The crown cap, the forehead arch and the
  flyaways are cheap and carry most of the silhouette.
* **Scales into face-anchor metres.** The file is 2.65 m across and centred
  0.79 m off origin. Conveniently it is already Y-up with +Z toward the
  forehead, which is the same convention as `FaceLandmark`, so no axis remap.

Run:  python3 tools/wig_to_mesh.py <wig.glb> facetrkr/Resources/wig.ftwg
"""

import json
import struct
import sys

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components

# Meshes belonging to the nine roller assemblies. Their wound hair goes too:
# it is positioned around rollers this app does not place in the same spots.
ROLLER_MESHES = {
    "recessed pink barrel",
    "silver hair wound round barrel",
    "pink end rims",
    "ivory end faces",
    "pink grille rings",
    "pink grille struts",
    "wound hair strands 1",
    "wound hair strands 2",
}

# Small enough to keep in full, and between them they carry the silhouette.
KEEP_WHOLE = {
    "silver crown beneath fine strands",
    "forehead arch and loose side locks",
    "fine crown flyaways",
}

# Triangles to aim for across the thinned meshes. The app already runs face
# tracking, a full-screen compute pass and HEVC encode every frame, so this is
# a deliberate ceiling rather than a quality target.
TRIANGLE_BUDGET = 95_000

# Where the wig should sit, in the face-anchor metres `FaceLandmark` uses.
# Width rather than height sets the scale because height is inflated by a few
# long trailing strands.
TARGET_WIDTH = 0.205
# Pulled back from a straight bounding-box match: aligning centres put the
# fringe at z = 0.075, which is nose-tip depth and a good 3 cm proud of the
# forehead. This lands its front edge around the brow plane instead.
TARGET_CENTRE = np.array([0.0, 0.062, -0.027], np.float32)

# The nine roller assemblies are dropped from the mesh, but their poses are
# worth keeping: the hair is modelled wound around them, so putting rollers
# anywhere else leaves barrel-shaped holes in it. The app rebuilds them at
# these transforms with its own textured materials.
ROLLER_PREFIX = "Roller"

COMPONENT_TYPES = {
    5120: np.int8, 5121: np.uint8, 5122: np.int16,
    5123: np.uint16, 5125: np.uint32, 5126: np.float32,
}
TYPE_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def load(path):
    handle = open(path, "rb")
    struct.unpack("<III", handle.read(12))
    length, _ = struct.unpack("<II", handle.read(8))
    gltf = json.loads(handle.read(length))
    length, _ = struct.unpack("<II", handle.read(8))
    return gltf, handle.read(length)


def accessor(gltf, blob, index):
    spec = gltf["accessors"][index]
    view = gltf["bufferViews"][spec["bufferView"]]
    dtype = COMPONENT_TYPES[spec["componentType"]]
    count = TYPE_COUNTS[spec["type"]]
    offset = view.get("byteOffset", 0) + spec.get("byteOffset", 0)
    flat = np.frombuffer(blob, dtype, spec["count"] * count, offset)
    return flat.reshape(spec["count"], count)


def node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], np.float32).reshape(4, 4).T
    matrix = np.eye(4, dtype=np.float32)
    if "scale" in node:
        matrix[:3, :3] = np.diag(np.array(node["scale"], np.float32))
    if "rotation" in node:
        x, y, z, w = node["rotation"]
        rotation = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ], np.float32)
        matrix[:3, :3] = rotation @ matrix[:3, :3]
    if "translation" in node:
        matrix[:3, 3] = np.array(node["translation"], np.float32)
    return matrix


def gather(gltf, blob):
    """World-space hair primitives, as (name, positions, normals, triangles)."""
    out = []

    def walk(index, parent):
        node = gltf["nodes"][index]
        world = parent @ node_matrix(node)
        if "mesh" in node:
            mesh = gltf["meshes"][node["mesh"]]
            name = mesh.get("name", "")
            if name not in ROLLER_MESHES:
                for primitive in mesh["primitives"]:
                    attributes = primitive["attributes"]
                    positions = accessor(gltf, blob, attributes["POSITION"]).astype(np.float32)
                    normals = accessor(gltf, blob, attributes["NORMAL"]).astype(np.float32)
                    if "indices" in primitive:
                        triangles = accessor(
                            gltf, blob, primitive["indices"]
                        ).astype(np.int64).reshape(-1, 3)
                    else:
                        triangles = np.arange(len(positions), dtype=np.int64).reshape(-1, 3)

                    positions = (world[:3, :3] @ positions.T).T + world[:3, 3]
                    # Normals ignore translation, and the transforms here are
                    # rotation plus uniform scale, so renormalising is enough.
                    normals = (world[:3, :3] @ normals.T).T
                    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
                    normals = normals / np.maximum(lengths, 1e-8)

                    out.append((
                        name,
                        primitive.get("material", 0),
                        positions,
                        normals.astype(np.float32),
                        triangles,
                    ))
        for child in node.get("children", []):
            walk(child, world)

    for root in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
        walk(root, np.eye(4, dtype=np.float32))
    return out


def strands(positions, triangles):
    """Connected component per vertex. Each component is one hair strand."""
    edges = np.vstack([
        triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]
    ])
    count = len(positions)
    graph = coo_matrix(
        (np.ones(len(edges), np.int8), (edges[:, 0], edges[:, 1])),
        shape=(count, count),
    )
    total, labels = connected_components(graph, directed=False)
    return total, labels


def thin(positions, normals, triangles, keep_fraction, seed):
    """Drops whole strands, never vertices."""
    if keep_fraction >= 1:
        return positions, normals, triangles

    total, labels = strands(positions, triangles)
    rng = np.random.default_rng(seed)
    keep = rng.random(total) < keep_fraction
    if not keep.any():
        keep[rng.integers(total)] = True

    mask = keep[labels[triangles[:, 0]]]
    triangles = triangles[mask]

    # Compact, so the output carries no orphaned vertices.
    used = np.unique(triangles)
    remap = np.full(len(positions), -1, np.int64)
    remap[used] = np.arange(len(used))
    return positions[used], normals[used], remap[triangles]


def quaternion(rotation):
    """Rotation matrix to (x, y, z, w), scale removed."""
    m = rotation / np.maximum(np.linalg.norm(rotation, axis=0), 1e-8)
    trace = m[0, 0] + m[1, 1] + m[2, 2]
    if trace > 0:
        s = 0.5 / np.sqrt(trace + 1.0)
        return np.array([(m[2, 1] - m[1, 2]) * s, (m[0, 2] - m[2, 0]) * s,
                         (m[1, 0] - m[0, 1]) * s, 0.25 / s])
    i = int(np.argmax([m[0, 0], m[1, 1], m[2, 2]]))
    j, k = (i + 1) % 3, (i + 2) % 3
    s = 2.0 * np.sqrt(1.0 + m[i, i] - m[j, j] - m[k, k])
    q = np.zeros(4)
    q[3] = (m[k, j] - m[j, k]) / s
    q[i] = 0.25 * s
    q[j] = (m[j, i] + m[i, j]) / s
    q[k] = (m[k, i] + m[i, k]) / s
    return q


def rollers(gltf, blob):
    """World pose of each roller group, plus the barrel's local dimensions."""
    poses = []

    def walk(index, parent):
        node = gltf["nodes"][index]
        world = parent @ node_matrix(node)
        name = node.get("name", "")
        if name.startswith(ROLLER_PREFIX):
            poses.append((name, world.copy()))
            return
        for child in node.get("children", []):
            walk(child, world)

    for root in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
        walk(root, np.eye(4, dtype=np.float32))

    barrel = rims = None
    for mesh in gltf["meshes"]:
        if mesh.get("name") in ("recessed pink barrel", "pink end rims"):
            positions = accessor(
                gltf, blob, mesh["primitives"][0]["attributes"]["POSITION"]
            ).astype(np.float32)
            size = positions.max(0) - positions.min(0)
            if mesh["name"] == "recessed pink barrel" and barrel is None:
                barrel = size
            elif rims is None:
                rims = size
    return poses, barrel, rims


def emit_swift(path, poses, barrel, rims, scale, centre):
    lines = [
        "// Generated by tools/wig_to_mesh.py. Do not edit by hand.",
        "//",
        "// Roller placements lifted from the supplied wig, because the hair is",
        "// modelled wound around them: put a roller anywhere else and the wrap it",
        "// sits in is left as a barrel-shaped hole. The sizes come from the same",
        "// source and are larger than a real roller, which is the look that asset",
        "// went for and what the hair is shaped to.",
        "",
        "import simd",
        "",
        "enum WigPlacement {",
        "",
        "    struct Roller {",
        "        let name: String",
        "        let position: SIMD3<Float>",
        "        let orientation: simd_quatf",
        "    }",
        "",
        f"    /// Barrel extent along its own X axis, in metres.",
        f"    static let barrelLength: Float = {barrel[0] * scale:.5f}",
        f"    static let barrelRadius: Float = {barrel[1] * scale / 2:.5f}",
        f"    static let rimRadius: Float = {rims[1] * scale / 2:.5f}",
        f"    static let rimLength: Float = {(rims[0] - barrel[0]) * scale / 2:.5f}",
        "",
        "    static let rollers: [Roller] = [",
    ]
    for name, world in poses:
        position = (world[:3, 3] - centre) * scale + TARGET_CENTRE
        q = quaternion(world[:3, :3])
        lines.append(
            f'        Roller(name: "{name}",\n'
            f"               position: SIMD3({position[0]:+.5f}, {position[1]:+.5f}, {position[2]:+.5f}),\n"
            f"               orientation: simd_quatf(ix: {q[0]:+.5f}, iy: {q[1]:+.5f}, "
            f"iz: {q[2]:+.5f}, r: {q[3]:+.5f})),"
        )
    lines += ["    ]", "}", ""]
    open(path, "w").write("\n".join(lines))
    print(f"wrote {path} ({len(poses)} rollers)")


def main():
    source, destination = sys.argv[1], sys.argv[2]
    budget = int(sys.argv[3]) if len(sys.argv) > 3 else TRIANGLE_BUDGET

    gltf, blob = load(source)
    primitives = gather(gltf, blob)

    whole = [p for p in primitives if p[0] in KEEP_WHOLE]
    thinned = [p for p in primitives if p[0] not in KEEP_WHOLE]

    fixed = sum(len(p[4]) for p in whole)
    variable = sum(len(p[4]) for p in thinned)
    fraction = min(1.0, max(0.02, (budget - fixed) / max(variable, 1)))
    print(f"keeping {fixed:,} fixed triangles, thinning {variable:,} to {fraction:.0%}")

    groups = {}
    for seed, (name, material, positions, normals, triangles) in enumerate(primitives):
        if name not in KEEP_WHOLE:
            positions, normals, triangles = thin(
                positions, normals, triangles, fraction, seed
            )
        if len(triangles) == 0:
            continue
        bucket = groups.setdefault(material, [[], [], []])
        offset = sum(len(chunk) for chunk in bucket[0])
        bucket[0].append(positions)
        bucket[1].append(normals)
        bucket[2].append(triangles + offset)

    merged = {}
    for material, (positions, normals, triangles) in groups.items():
        merged[material] = (
            np.concatenate(positions),
            np.concatenate(normals),
            np.concatenate(triangles),
        )

    # One transform across every group, from the combined bounds, or the groups
    # would drift apart. Percentiles rather than extremes: a handful of stray
    # flyaways should not set the scale for the whole wig.
    everything = np.concatenate([p for p, _, _ in merged.values()])
    low = np.percentile(everything, 1, axis=0)
    high = np.percentile(everything, 99, axis=0)
    scale = TARGET_WIDTH / float(high[0] - low[0])
    centre = (high + low) / 2

    print(f"source width {high[0] - low[0]:.3f}m -> scale {scale:.5f}")

    chunks = [b"FTWG", struct.pack("<II", 1, len(merged))]
    total_triangles = 0
    for material in sorted(merged):
        positions, normals, triangles = merged[material]
        positions = (positions - centre) * scale + TARGET_CENTRE

        colour = gltf["materials"][material].get("pbrMetallicRoughness", {})
        base = colour.get("baseColorFactor", [0.8, 0.8, 0.8, 1])[:3]

        chunks.append(struct.pack(
            "<3fffII",
            base[0], base[1], base[2],
            float(colour.get("roughnessFactor", 0.85)),
            float(colour.get("metallicFactor", 0.0)),
            len(positions), triangles.size,
        ))
        chunks.append(positions.astype("<f4").tobytes())
        chunks.append(normals.astype("<f4").tobytes())
        chunks.append(triangles.astype("<u4").ravel().tobytes())

        total_triangles += len(triangles)
        print(f"  group {material}: {len(positions):,} verts, {len(triangles):,} tris")

    data = b"".join(chunks)
    open(destination, "wb").write(data)

    if len(sys.argv) > 4:
        poses, barrel, rims = rollers(gltf, blob)
        emit_swift(sys.argv[4], poses, barrel, rims, scale, centre)

    low = np.concatenate([
        ((p - centre) * scale + TARGET_CENTRE) for p, _, _ in merged.values()
    ])
    print(f"\n{total_triangles:,} triangles, {len(data) / 1e6:.2f} MB -> {destination}")
    print("bounds min", np.round(low.min(0), 4), "max", np.round(low.max(0), 4))


if __name__ == "__main__":
    main()
