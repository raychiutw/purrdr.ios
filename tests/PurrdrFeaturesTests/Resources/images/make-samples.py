"""產生圖片前處理測試用的合成樣本(無版權：全由程式產生，字型是 Pillow 內建的 Aileron)。

用法:python make-samples.py <輸出資料夾>(需要 pillow、numpy)。亂數種子固定，輸出可重現。
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

out = Path(sys.argv[1])
rng = np.random.default_rng(76)


def natural_image(width, height):
    """1/f 頻譜的彩色雜訊(接近自然影像的統計)加感光雜訊。"""
    fy = np.fft.fftfreq(height)[:, None]
    fx = np.fft.rfftfreq(width)[None, :]
    falloff = 1.0 / np.maximum(np.sqrt(fx * fx + fy * fy), 1.0 / max(width, height)) ** 1.1

    def field():
        phases = np.exp(2j * np.pi * rng.random((height, width // 2 + 1)))
        return np.fft.irfft2(falloff * phases, s=(height, width))

    base = field()
    pixels = np.stack([weight * base + 0.35 * field() for weight in (1.0, 0.9, 0.75)], axis=-1)
    pixels = (pixels - pixels.mean()) / pixels.std()
    pixels = 128 + 48 * pixels + rng.normal(0, 4, pixels.shape)
    return Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8))


photo = natural_image(4032, 3024)
photo.save(out / "photo-4032x3024.jpg", quality=85)

width, height = 1290, 2796
screenshot = Image.new("RGB", (width, height), (28, 28, 30))
screenshot.paste(photo.resize((1194, 1500)), (48, 220))
draw = ImageDraw.Draw(screenshot)
title_font = ImageFont.load_default(size=54)
body_font = ImageFont.load_default(size=32)
draw.text((48, 110), "Purrdr Sample Chat", font=title_font, fill=(242, 242, 247))
words = ("agent workspace pane terminal upload compress quality resolution screenshot readable "
         "session folder photo network deadline").split()
fixed_lines = {
    3: "Build failed: error PX-4821 in ImageCodec.swift line 207",
    9: "Deploy token expires at 17:45 on Thursday",
    15: "Ledger balance 3,915.62 after refund",
}
y = 1770
line_number = 0
while y < height - 80:
    line_number += 1
    if line_number % 6 == 1:
        draw.rounded_rectangle((40, y - 6, width - 40, y + 44), radius=18, fill=(44, 44, 46))
    text = fixed_lines.get(line_number) or f"{line_number:02d} " + " ".join(words[i] for i in rng.choice(len(words), size=7))
    draw.text((64, y), text, font=body_font, fill=(235, 235, 245) if line_number % 4 else (100, 210, 255))
    y += 50
screenshot.save(out / "screenshot-1290x2796.png", optimize=True)
