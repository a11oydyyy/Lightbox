# Lightbox app icon, step 3: the .iconset.
# Area-averages the 1024 px master down to every icon size (premultiplied), sharpens 16/32 px a
# little, and writes 8-bit PNGs with triangular dither so the gradients don't band.
# Run with Blender's Python: blender -b --factory-startup -P iconset.py -- <master.png> <out.iconset>
import bpy, os, sys
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
MASTER, OUT = argv[0], argv[1]
os.makedirs(OUT, exist_ok=True)

im = bpy.data.images.load(MASTER); im.colorspace_settings.name = 'Non-Color'
a = np.array(im.pixels[:], np.float32).reshape(1024, 1024, 4)[::-1]
prem = np.concatenate([a[..., :3] * a[..., 3:4], a[..., 3:4]], -1)

def down(p, s):
    k = 1024 // s
    return p.reshape(s, k, s, k, 4).mean(axis=(1, 3))

def sharpen(p, amt):
    b = p.copy()
    b[1:-1, 1:-1] = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] + 4 * p[1:-1, 1:-1]) / 8
    r = p + amt * (p - b)
    r[..., 3] = np.clip(r[..., 3], 0, 1)
    r[..., :3] = np.clip(r[..., :3], 0, r[..., 3:4])
    return r

NAMES = (("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
         ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
         ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024))

for s in (16, 32, 64, 128, 256, 512, 1024):
    p = down(prem, s) if s < 1024 else prem
    if s <= 32:
        p = sharpen(p, 0.35)
    al = p[..., 3:4]
    st = np.concatenate([np.where(al > 1e-5, p[..., :3] / np.maximum(al, 1e-5), 0), al], -1)
    rng = np.random.default_rng(s)
    st[..., :3] += (rng.random(st[..., :3].shape) - rng.random(st[..., :3].shape)) / 255
    st = np.clip(st, 0, 1)
    img = bpy.data.images.new("i%d" % s, s, s, alpha=True, float_buffer=False)   # 8-bit, straight alpha
    img.colorspace_settings.name = 'Non-Color'
    img.pixels.foreach_set(st[::-1].astype(np.float32).ravel())
    for name, size in NAMES:
        if size == s:
            img.filepath_raw = os.path.join(OUT, name + ".png"); img.file_format = 'PNG'; img.save()
print("WROTE", OUT)
