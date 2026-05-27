#!/usr/bin/env python3
"""Generate a simple icon.png for AirPodsReconnectFix."""
from PIL import Image, ImageDraw

S = 120
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# rounded-rect background, Bluetooth blue
r = 26
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=r, fill=(0, 122, 255, 255))

# two "AirPod" stems
white = (255, 255, 255, 255)
for cx in (42, 78):
    d.ellipse([cx - 11, 30, cx + 11, 52], fill=white)          # bud
    d.rounded_rectangle([cx - 5, 46, cx + 5, 86], radius=5, fill=white)  # stem

# reconnect arrows (two arcs forming a loop) under the buds
d.arc([34, 70, 86, 104], start=20, end=200, fill=white, width=5)
d.arc([34, 70, 86, 104], start=200, end=380, fill=(255, 255, 255, 140), width=5)

img.save("icon.png")
print("wrote icon.png")
