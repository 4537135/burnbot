#!/usr/bin/env python3
"""Exports the Locked-in voxel Burnbot from tools/turnaround.py as a 3D model.

  python3 tools/export_model.py [out_dir]     default: shots/turnaround/locked-in/model

Writes burnbot-locked-in.glb (one material per colour; the face, lights and bulb glow) and
burnbot-locked-in.obj + .mtl. One voxel is 1 cm, so the robot stands about 54 cm tall, feet on
the ground at the origin, facing +Z, Y up.
"""
import json
import os
import struct
import sys

import numpy as np

out = sys.argv[1] if len(sys.argv) > 1 else 'shots/turnaround/locked-in/model'
sys.argv = sys.argv[:1]  # turnaround reads its own out dir from argv
sys.path.insert(0, os.path.dirname(__file__))
import turnaround as T  # noqa: E402

UNIT = 0.01
NAMES = {1: 'body', 2: 'trim', 3: 'limbs', 4: 'feet', 5: 'screen', 6: 'light', 7: 'glow',
         8: 'eye_halo', 9: 'headband', 10: 'earcups'}

# group the faces by material, as triangles wound counter-clockwise from outside
groups = {}
for c, n, m in zip(T.corners, T.norms, T.mats):
    ax = int(np.argmax(np.abs(n)))
    u, v = [i for i in range(3) if i != ax]
    eu, ev = np.eye(3)[u], np.eye(3)[v]
    quad = c if np.cross(eu, ev) @ n > 0 else c[::-1]
    groups.setdefault(int(m), []).append((quad * UNIT, n))

os.makedirs(out, exist_ok=True)
base = os.path.join(out, 'burnbot-locked-in')

# ---- OBJ + MTL ----
with open(base + '.mtl', 'w') as f:
    for m, name in NAMES.items():
        col, emissive = T.MAT[m]
        r, g, b = (x / 255 for x in col)
        f.write(f'newmtl {name}\nKd {r:.4f} {g:.4f} {b:.4f}\n')
        if emissive and m != 5:
            f.write(f'Ke {r:.4f} {g:.4f} {b:.4f}\n')
        f.write('Ns 40\n\n')
with open(base + '.obj', 'w') as f:
    f.write('# Burnbot, Locked in (level 4 of 5). 1 unit = 1 m.\nmtllib burnbot-locked-in.mtl\n')
    index, verts, normals = {}, [], []
    nidx = {}
    body = []
    for m, faces in groups.items():
        body.append(f'usemtl {NAMES[m]}\n')
        for quad, n in faces:
            key_n = tuple(n)
            if key_n not in nidx:
                nidx[key_n] = len(normals) + 1
                normals.append(key_n)
            ids = []
            for p in quad:
                k = tuple(np.round(p, 5))
                if k not in index:
                    index[k] = len(verts) + 1
                    verts.append(k)
                ids.append(index[k])
            body.append('f ' + ' '.join(f'{i}//{nidx[key_n]}' for i in ids) + '\n')
    f.writelines(f'v {x:.4f} {y:.4f} {z:.4f}\n' for x, y, z in verts)
    f.writelines(f'vn {x:.0f} {y:.0f} {z:.0f}\n' for x, y, z in normals)
    f.writelines(body)

# ---- GLB ----
bin_, views, accessors, meshes_prims, materials = bytearray(), [], [], [], []

def add_view(data, target):
    while len(bin_) % 4:
        bin_.append(0)
    views.append({'buffer': 0, 'byteOffset': len(bin_), 'byteLength': len(data), 'target': target})
    bin_.extend(data)
    return len(views) - 1

for mi, (m, faces) in enumerate(sorted(groups.items())):
    col, emissive = T.MAT[m]
    rgb = [(x / 255) ** 2.2 for x in col]  # glTF colours are linear
    mat = {'name': NAMES[m], 'pbrMetallicRoughness': {'baseColorFactor': rgb + [1], 'metallicFactor':
           0.0 if m in (5, 6, 7, 8) else 0.35, 'roughnessFactor': 0.55}}
    if emissive and m != 5:
        mat['emissiveFactor'] = rgb
    materials.append(mat)
    pos = np.array([q for quad, _ in faces for q in quad], dtype=np.float32)
    nor = np.array([n for _, n in faces for _ in range(4)], dtype=np.float32)
    idx = np.array([[4 * i, 4 * i + 1, 4 * i + 2, 4 * i, 4 * i + 2, 4 * i + 3] for i in range(len(faces))],
                   dtype=np.uint32).ravel()
    pv, nv, iv = add_view(pos.tobytes(), 34962), add_view(nor.tobytes(), 34962), add_view(idx.tobytes(), 34963)
    a = len(accessors)
    accessors += [
        {'bufferView': pv, 'componentType': 5126, 'count': len(pos), 'type': 'VEC3',
         'min': pos.min(0).tolist(), 'max': pos.max(0).tolist()},
        {'bufferView': nv, 'componentType': 5126, 'count': len(nor), 'type': 'VEC3'},
        {'bufferView': iv, 'componentType': 5125, 'count': len(idx), 'type': 'SCALAR'},
    ]
    meshes_prims.append({'attributes': {'POSITION': a, 'NORMAL': a + 1}, 'indices': a + 2, 'material': mi})

gltf = {
    'asset': {'version': '2.0', 'generator': 'burnbot tools/export_model.py'},
    'scene': 0, 'scenes': [{'nodes': [0]}],
    'nodes': [{'name': 'Burnbot (Locked in)', 'mesh': 0}],
    'meshes': [{'name': 'burnbot', 'primitives': meshes_prims}],
    'materials': materials, 'accessors': accessors, 'bufferViews': views,
    'buffers': [{'byteLength': len(bin_)}],
}
js = json.dumps(gltf, separators=(',', ':')).encode()
js += b' ' * (-len(js) % 4)
while len(bin_) % 4:
    bin_.append(0)
glb = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_))
glb += struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(bin_), 0x004E4942) + bytes(bin_)
with open(base + '.glb', 'wb') as f:
    f.write(glb)

tris = sum(len(f) for f in groups.values()) * 2
print(f'{tris} triangles -> {base}.glb, .obj, .mtl')
