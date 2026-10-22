# Lightbox app icon, step 2: shading.
# Shades gen.py's two-tone silhouette: a deep indigo L lit by the panel, and a light-emitting
# diffuser panel with a soft rounded rim. Works at SS x resolution with re-antialiased masks.
# Run with Blender's Python: blender -b --factory-startup -P restyle.py -- <silhouette.png> <out.png>
import bpy, sys, json
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
GEO = json.load(open(SRC + ".json"))
SS = 3

def hexc(h):
    h = h.lstrip('#'); return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)

def blur(a, r):
    """~gaussian blur; r in 1024-px units"""
    r = int(round(r * SS))
    if r < 1:
        return a
    for axis in (0, 1):
        for _ in range(3):
            p = np.pad(a, [(r + 1, r) if ax == axis else (0, 0) for ax in range(a.ndim)], mode='edge')
            c = np.cumsum(p, axis=axis, dtype=np.float64)
            hi = np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis)
            lo = np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)
            a = ((hi - lo) / (2 * r + 1)).astype(np.float32)
    return a

def upsample(img, k):
    """bilinear upsample by integer factor k (pixel-centre aligned)"""
    H, W = img.shape[:2]
    def axis_coords(n):
        s = (np.arange(n * k) + 0.5) / k - 0.5
        i0 = np.clip(np.floor(s).astype(int), 0, n - 1); i1 = np.clip(i0 + 1, 0, n - 1)
        return i0, i1, np.clip(s - np.floor(s), 0, 1).astype(np.float32)
    y0, y1, fy = axis_coords(H); x0, x1, fx = axis_coords(W)
    sh = (-1,) + (1,) * (img.ndim - 1)
    rows = img[y0] * (1 - fy.reshape(sh)) + img[y1] * fy.reshape(sh)
    shx = (1, -1) + (1,) * (img.ndim - 2)
    return rows[:, x0] * (1 - fx.reshape(shx)) + rows[:, x1] * fx.reshape(shx)

def downsample(img, k):
    H, W = img.shape[:2]
    return img.reshape(H // k, k, W // k, k, *img.shape[2:]).mean(axis=(1, 3))

def clean(m, r=2.0):
    """smooth a mask's contour (removes stair-steps) and re-antialias it to a 1-pixel ramp"""
    b = blur(m, r)
    gy, gx = np.gradient(b)
    g = np.sqrt(gx * gx + gy * gy)
    sd = (b - 0.5) / np.maximum(g, 1e-4)            # signed distance in working pixels
    return np.where(g > 1e-4, np.clip(sd + 0.5, 0, 1), (b > 0.5).astype(np.float32)).astype(np.float32)

def ramp(t, stops):
    t = np.clip(t, 0, 1)[..., None]
    out = np.zeros(t.shape[:-1] + (3,), np.float32)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (t >= p0) & (t <= p1)
        f = np.clip((t - p0) / max(p1 - p0, 1e-6), 0, 1)
        f = f * f * (3 - 2 * f)
        out = np.where(m, hexc(c0) * (1 - f) + hexc(c1) * f, out)
    return out

def smooth(x, a, b):
    t = np.clip((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)

def edge_dir(mask, r, d):
    """band of width ~r just inside mask's edge, and how much its outward normal faces direction d"""
    m = blur(mask, r)
    n = blur(mask, max(r, 3))                        # wider blur gives stable normals
    gy, gx = np.gradient(n)
    ln = np.sqrt(gx * gx + gy * gy) + 1e-6
    facing = np.clip((-gx * d[0] - gy * d[1]) / ln, 0, 1)
    band = np.clip((1 - m) * 2, 0, 1) * mask
    return band, facing

def homography(dst):
    """unit square (TL, TR, BR, BL) -> dst"""
    M = []
    for (u, v), (x, y) in zip([(0, 0), (1, 0), (1, 1), (0, 1)], dst):
        M.append([u, v, 1, 0, 0, 0, -u * x, -v * x, x])
        M.append([0, 0, 0, u, v, 1, -u * y, -v * y, y])
    M = np.array(M, float)
    return np.append(np.linalg.solve(M[:, :8], M[:, 8]), 1).reshape(3, 3)

# ---------- masks ----------
im = bpy.data.images.load(SRC); im.colorspace_settings.name = 'Non-Color'
N0 = im.size[0]
src = np.array(im.pixels[:], np.float32).reshape(N0, N0, 4)[::-1]   # top-down, straight
lum0 = src[..., :3] @ np.array([.2126, .7152, .0722], np.float32)
A0 = src[..., 3]
body_hard = ((lum0 < 0.58) & (A0 > 0.5)).astype(np.float32)
N = N0 * SS
A = clean(upsample(A0, SS))                      # whole object
B_in = clean(upsample(body_hard, SS))            # the L
F = np.clip(A - B_in, 0, 1)                      # the panel
yy, xx = (np.mgrid[0:N, 0:N].astype(np.float32) + 0.5) / N

# panel (perspective) coordinates: U, V in 0..1 across the panel
QUAD = [tuple(q) for q in GEO["quad"]]
Hm = np.linalg.inv(homography([(x / 1024, y / 1024) for x, y in QUAD]))
den = Hm[2, 0] * xx + Hm[2, 1] * yy + Hm[2, 2]
U = (Hm[0, 0] * xx + Hm[0, 1] * yy + Hm[0, 2]) / den
V = (Hm[1, 0] * xx + Hm[1, 1] * yy + Hm[1, 2]) / den
diag = np.clip((U + V) / 2, 0, 1)                # 0 at the panel's upper left, 1 at its lower right

# ---------- the L ----------
t = ((xx - 0.14) * 0.62 + (yy - 0.18) * 0.78) / 0.85
body = ramp(t, [(0.0, "#17184A"), (0.42, "#2E31A0"), (0.78, "#5A5EE0"), (1.0, "#9195FA")])
# soft facet seam from the panel's lower-left corner to the outer lower-left corner
p0, p1 = np.array(GEO["seam"][0]), np.array(GEO["seam"][1])
dv = p1 - p0; nv = np.array([dv[1], -dv[0]]) / np.linalg.norm(dv)
left_facet = smooth((xx - p0[0]) * nv[0] + (yy - p0[1]) * nv[1], -0.012, 0.012)
body *= (1 - left_facet[..., None] * 0.10)
body *= (1 + (1 - left_facet[..., None]) * 0.10 * 0.4)
# a little contact shade right at the seam
body *= (1 - 0.06 * blur(F, 6)[..., None])
# lacquer sheen along the left facet
inner = blur(A, 34)
sheen = smooth(inner, 0.55, 0.8) * (1 - smooth(inner, 0.86, 0.98)) * left_facet
body += sheen[..., None] * 0.06 * hexc("#B9BCFF")
# outer rims: cool light on up-left edges (definition on dark Docks), bright on lower-right edges
band, face_ul = edge_dir(A, 3, (-0.6, -0.8))
_, face_lr = edge_dir(A, 3, (0.55, 0.83))
body = body + band[..., None] * (face_ul[..., None] * 0.42 * hexc("#9EA2FF")
                                 + face_lr[..., None] * 0.26 * hexc("#C9CBFF"))

# ---------- the panel: a light-emitting diffuser ----------
# even brightness from the centre, with only a faint lavender falloff toward the rim
fe = (np.abs(2 * U - 1) ** 6 + np.abs(2 * V - 1) ** 6) ** (1 / 6)
face = ramp(np.clip(fe, 0, 1), [(0, "#FFFFFF"), (0.6, "#FAFBFF"), (1, "#CDD4F4")])
# soft rounded rim: a crease-free superellipse height field in panel coordinates
RIM = 45.0                                       # rim width, 1024-px units
f = (np.abs(2 * U - 1) ** 6 + np.abs(2 * V - 1) ** 6) ** (1 / 6) * 0.95
side_px = float(np.mean([np.hypot(QUAD[i][0] - QUAD[(i + 1) % 4][0], QUAD[i][1] - QUAD[(i + 1) % 4][1]) for i in range(4)]))
s_ = np.clip((1 - f) * side_px / 2 / RIM, 0, 1)
hgt = RIM * (1 - (1 - s_) ** 3)
hy, hx = np.gradient(hgt)
hx *= SS; hy *= SS                               # per 1024-px
nl = np.sqrt(hx * hx + hy * hy + 1)
nx, ny, nz = -hx / nl, -hy / nl, 1 / nl
Lv = np.array([-0.45, -0.7, 0.55]); Lv /= np.linalg.norm(Lv)
face *= (1 + 0.04 * (nx * Lv[0] + ny * Lv[1] + nz * Lv[2] - Lv[2]))[..., None]
Hv = Lv + np.array([0, 0, 1.0]); Hv /= np.linalg.norm(Hv)
nh = nx * Hv[0] + ny * Hv[1] + nz * Hv[2]
spec = np.clip((nh - Hv[2]) / (1 - Hv[2]), 0, 1) ** 3   # only where the rim turns toward the light
kf = np.clip((1 - nz) ** 2 * 0.6, 0, 1)                  # lavender translucency on the rim
face = face * (1 - kf[..., None]) + ramp(diag, [(0, "#B9C4FF"), (0.5, "#B4AEFF"), (1, "#C9B4F5")]) * kf[..., None]
face += (spec * 0.08)[..., None]
# hairlines: faint bright line where the panel meets the L, lavender line on its outer edges
fband, f_bl = edge_dir(F, 1.3, (-0.75, 0.66))
near_body = smooth(blur(B_in, 3), 0.02, 0.15)
face = face + (fband * f_bl * near_body)[..., None] * 0.06
outline = fband * (1 - near_body) * 0.2
face = face * (1 - outline[..., None] * (1 - hexc("#A7AEE6")))

# the panel's light spills onto the L just outside the seam
sp = blur(F, 18) * (1 - smooth(F, 0.0, 0.5))
body = body + ramp(diag, [(0, "#C7D2FF"), (0.5, "#C4C0FF"), (1, "#D6C4FF")]) * (sp * 0.5)[..., None]

Fw = np.where(A > 1e-4, np.clip(F / np.maximum(A, 1e-4), 0, 1), 0)
rgb = body * (1 - Fw[..., None]) + face * Fw[..., None]

# ---------- soft drop shadow, downsample, grain ----------
sh = blur(np.roll(A, int(round(14 * SS)), axis=0), 16) * 0.22
outa = A + sh * (1 - A)
prem = rgb * A[..., None] + hexc("#0E0F2E") * (sh * (1 - A))[..., None]
prem = downsample(prem, SS); outa = downsample(outa, SS)
prem += np.random.default_rng(7).standard_normal(prem.shape).astype(np.float32) * 0.002 * outa[..., None]
prem = np.clip(prem, 0, outa[..., None])

# Blender treats float buffers as premultiplied when writing PNG
out = np.concatenate([prem, outa[..., None]], -1)[::-1]
img = bpy.data.images.new("icon", N0, N0, alpha=True, float_buffer=True)
img.colorspace_settings.name = 'Non-Color'
img.pixels.foreach_set(out.astype(np.float32).ravel())
img.filepath_raw = OUT; img.file_format = 'PNG'; img.save()
print("WROTE", OUT)
