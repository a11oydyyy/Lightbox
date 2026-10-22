# Lightbox app icon, step 1: the silhouette.
# A rounded front panel and the rounded hull swept back to its back face, drawn as a flat
# two-tone image (body dark, panel light) that restyle.py shades, plus the panel geometry.
# Run with Blender's Python: blender -b --factory-startup -P gen.py -- <out.png>
import bpy, sys, json
import numpy as np

OUT = sys.argv[sys.argv.index("--") + 1]
N = 1024

# Panel corners of the original icon (TL, TR, BR, BL) and its mean extrusion toward the lower left.
PANEL = [(327.9, 106.6), (924.8, 153.1), (887.8, 681.8), (376.1, 742.8)]
EXTRUSION = (-227.0, 199.0)
DEPTH = 0.70          # extrusion relative to the original: a lighter, thinner L
BACK_SCALE = 0.97     # back face slightly smaller, so the depth lines converge a little
RADIUS = 70.0         # corner radius before fitting
FIT = 818.0           # longest side of the whole shape, in pixels
CENTRE = (511.0, 510.0)

def back_face(pts, k, t):
    c = np.mean(pts, axis=0)
    return [c + k * (np.array(p) - c) + np.array(t) for p in pts]

front = [np.array(p, float) for p in PANEL]
back = back_face(PANEL, BACK_SCALE, (EXTRUSION[0] * DEPTH, EXTRUSION[1] * DEPTH))

# fit the shape into the original's footprint (the rounded shapes lie inside their sharp polygons)
allp = np.array(front + back)
lo, hi = allp.min(0), allp.max(0)
scale = FIT / max(hi - lo)
def fit(p):
    return (p - (lo + hi) / 2) * scale + np.array(CENTRE)
front = [fit(p) for p in front]
back = [fit(p) for p in back]
r = RADIUS * scale

yy, xx = (np.mgrid[0:N, 0:N].astype(np.float64) + 0.5)

def poly_sdf(poly):
    """exact signed distance to a polygon (negative inside)"""
    v = np.array(poly)
    d = np.full(xx.shape, np.inf); s = np.ones(xx.shape)
    for i in range(len(v)):
        a, b = v[i], v[(i + 1) % len(v)]
        ex, ey = b - a
        wx, wy = xx - a[0], yy - a[1]
        t = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey), 0, 1)
        dx, dy = wx - ex * t, wy - ey * t
        d = np.minimum(d, dx * dx + dy * dy)
        c1 = yy >= a[1]; c2 = yy < b[1]; c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
    return s * np.sqrt(d)

def inset(poly, r):
    """move each edge of a convex polygon inward by r"""
    v = [np.array(p) for p in poly]; n = len(v)
    area = sum(v[i][0] * v[(i + 1) % n][1] - v[(i + 1) % n][0] * v[i][1] for i in range(n))
    sgn = 1 if area > 0 else -1
    lines = []
    for i in range(n):
        a, b = v[i], v[(i + 1) % n]
        e = (b - a) / np.linalg.norm(b - a)
        lines.append((a + np.array([-e[1], e[0]]) * sgn * r, e))
    out = []
    for i in range(n):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        s_ = np.linalg.solve(np.array([d1, -d2]).T, p2 - p1)
        out.append(p1 + d1 * s_[0])
    return out

def hull(points):
    pts = sorted(map(tuple, points))
    def cross(o, a, b): return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0: lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0: upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]

fi = inset(front, r)
bi = inset(back, r * BACK_SCALE)
F = np.clip(0.5 - (poly_sdf(fi) - r), 0, 1)
A = np.maximum(np.clip(0.5 - (poly_sdf(hull(fi + bi)) - r), 0, 1), F)

body_c = np.array([0.20, 0.20, 0.44]); face_c = np.array([0.94, 0.95, 1.0])
rgb = np.where(A[..., None] > 1e-6, (F[..., None] * face_c + (A - F)[..., None] * body_c) / np.maximum(A, 1e-6)[..., None], 0)
img = bpy.data.images.new("silhouette", N, N, alpha=True, float_buffer=False)   # 8-bit, straight alpha
img.colorspace_settings.name = 'Non-Color'
img.pixels.foreach_set(np.concatenate([rgb, A[..., None]], -1)[::-1].astype(np.float32).ravel())
img.filepath_raw = OUT; img.file_format = 'PNG'; img.save()

# the facet seam runs between the visible (rounded) lower-left corners of the front and back faces
def soft_corner(sharp, ins): return sharp + (ins - sharp) * 0.55
geo = {"quad": [list(map(float, p)) for p in front],
       "seam": [list(map(float, soft_corner(front[3], fi[3]) / N)), list(map(float, soft_corner(back[3], bi[3]) / N))]}
with open(OUT + ".json", "w") as f:
    json.dump(geo, f)
print("WROTE", OUT)
