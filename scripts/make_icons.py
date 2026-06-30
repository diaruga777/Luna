#!/usr/bin/env python3
"""Generate the three Quartz app icons (faceted crystal + glyph), 1024x1024 PNG.

Quartz-stone aesthetic: a cool diagonal gradient overlaid with translucent angular
facets (crystal planes), each app a distinct quartz variety, with a bold white glyph
and soft shadow. Rendered at 4x and downsampled (LANCZOS) for clean edges.
"""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4
W = S * SS
WHITE = (255, 255, 255, 255)

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))

def gradient(top, bottom, n=160):
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            px[x, y] = lerp(top, bottom, (x + y) / (2 * (n - 1)))
    return img.resize((W, W), Image.BICUBIC).convert("RGBA")

FACETS = [
    ([(0,0),(0.55,0),(0.30,0.45)], (255,255,255,40)),
    ([(0.55,0),(1,0),(1,0.35),(0.62,0.30)], (0,0,0,36)),
    ([(0,0),(0.30,0.45),(0,0.62)], (0,0,0,28)),
    ([(0.30,0.45),(0.62,0.30),(0.72,0.66),(0.40,0.78)], (255,255,255,32)),
    ([(0,0.62),(0.30,0.45),(0.40,0.78),(0,1)], (255,255,255,22)),
    ([(0.40,0.78),(0.72,0.66),(1,1),(0,1)], (0,0,0,32)),
    ([(0.62,0.30),(1,0.35),(1,1),(0.72,0.66)], (255,255,255,18)),
]

def add_facets(img):
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for poly, rgba in FACETS:
        d.polygon([(int(x * W), int(y * W)) for x, y in poly], fill=rgba)
    return Image.alpha_composite(img, overlay)

def rrect(d, box, r, fill): d.rounded_rectangle(box, radius=r, fill=fill)

def glyph_book(d):
    cx, cy = W/2, W/2
    w, h = W*0.46, W*0.34
    spine = W*0.02
    rrect(d, (cx - w/2, cy - h/2, cx - spine/2, cy + h/2), r=W*0.02, fill=WHITE)
    rrect(d, (cx + spine/2, cy - h/2, cx + w/2, cy + h/2), r=W*0.02, fill=WHITE)
    for i in range(4):
        yy = cy - h*0.28 + i*(h*0.17)
        d.line([(cx - w*0.45, yy), (cx - spine*1.6, yy)], fill=(90,80,140,110), width=int(W*0.012))
        d.line([(cx + spine*1.6, yy), (cx + w*0.45, yy)], fill=(90,80,140,110), width=int(W*0.012))

def glyph_download(d):
    cx = W/2
    cy = W*0.44
    sw = W*0.09
    s_top = cy - W*0.19
    s_bot = cy + W*0.05
    rrect(d, (cx - sw/2, s_top, cx + sw/2, s_bot), r=sw/2, fill=WHITE)
    ah = W*0.155
    d.polygon([(cx - ah, s_bot - W*0.01), (cx + ah, s_bot - W*0.01), (cx, s_bot + ah)], fill=WHITE)
    tw = W*0.40
    by = cy + W*0.30
    d.line([(cx - tw/2, by - W*0.07), (cx - tw/2, by), (cx + tw/2, by), (cx + tw/2, by - W*0.07)],
           fill=WHITE, width=int(W*0.028), joint="curve")

def glyph_graph(d):
    ax, ay, aw = W*0.30, W*0.70, W*0.42
    d.line([(ax, W*0.28), (ax, ay), (ax + aw, ay)], fill=(255,255,255,150), width=int(W*0.018), joint="curve")
    pts = [(ax + aw*0.02, ay - W*0.02), (ax + aw*0.24, ay - W*0.11),
           (ax + aw*0.44, ay - W*0.06), (ax + aw*0.68, ay - W*0.21), (ax + aw*0.94, ay - W*0.31)]
    d.line(pts, fill=WHITE, width=int(W*0.028), joint="curve")
    px, py = pts[-1]
    r = W*0.03
    d.ellipse((px - r, py - r, px + r, py + r), fill=WHITE)
    a = W*0.052
    d.polygon([(px, py - W*0.105 - a), (px - a*0.85, py - W*0.105), (px + a*0.85, py - W*0.105)], fill=WHITE)

SPECS = {
    "AppIconReader":       (((150,123,214),(70,44,116)),  glyph_book),
    "AppIconDownloader":   (((96,210,226),(26,100,148)),  glyph_download),
    "AppIconPriceTracker": (((244,168,194),(176,62,108)), glyph_graph),
}

def build(palette, glyph):
    img = add_facets(gradient(*palette))
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    glyph(ImageDraw.Draw(layer))
    alpha = layer.split()[3]
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 130), (0, 0, W, W), alpha.filter(ImageFilter.GaussianBlur(W * 0.018)))
    out = Image.alpha_composite(img, shadow)
    out = Image.alpha_composite(out, layer)
    return out.convert("RGB").resize((S, S), Image.LANCZOS)

OUT = os.path.join(os.path.dirname(__file__), "..", "Clip", "Assets.xcassets")
CONTENTS = ('{\n  "images" : [\n    {\n      "filename" : "%s-1024.png",\n'
            '      "idiom" : "universal",\n      "platform" : "ios",\n'
            '      "size" : "1024x1024"\n    }\n  ],\n'
            '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')

for name, (palette, glyph) in SPECS.items():
    img = build(palette, glyph)
    setdir = os.path.join(OUT, name + ".appiconset")
    os.makedirs(setdir, exist_ok=True)
    img.save(os.path.join(setdir, name + "-1024.png"))
    with open(os.path.join(setdir, "Contents.json"), "w") as f:
        f.write(CONTENTS % name)
    print("wrote", os.path.relpath(setdir))
print("done")
