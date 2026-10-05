#!/usr/bin/env python3
"""Compare the RTL framebuffer dump with the scene's reference image
(TinyGPU's software rendering, or TinyH264's own RGB565 for the video).

Usage: compare.py expected.hex actual.hex [diff.ppm]

Both files hold one native RGB565 value (4 hex digits) per line, 320x240
row-major. Prints the number of differing pixels (and the first few), and
optionally writes a PPM image: expected | actual | difference (red).
Exit status 0 only if the two are identical.
"""
import sys

W, H = 320, 240


def load(path):
    with open(path) as f:
        vals = [int(line, 16) for line in f if line.strip()]
    if len(vals) != W * H:
        sys.exit(f"{path}: {len(vals)} pixels, expected {W * H}")
    return vals


def rgb(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def main():
    exp, act = load(sys.argv[1]), load(sys.argv[2])
    diffs = [i for i in range(W * H) if exp[i] != act[i]]
    for i in diffs[:20]:
        print(f"  ({i % W:3d},{i // W:3d}) expected {exp[i]:04x} got {act[i]:04x}")
    if len(sys.argv) > 3:
        with open(sys.argv[3], "wb") as f:
            f.write(f"P6 {3 * W + 16} {H} 255\n".encode())
            for y in range(H):
                row = bytearray()
                for img in (exp, act):
                    for x in range(W):
                        row += bytes(rgb(img[y * W + x]))
                    row += bytes(8 * 3 * [128])
                for x in range(W):
                    i = y * W + x
                    row += b"\xff\x00\x00" if exp[i] != act[i] else bytes(c // 4 for c in rgb(exp[i]))
                f.write(row[: (3 * W + 16) * 3])
    if diffs:
        print(f"FAIL golden: {len(diffs)} of {W * H} pixels differ")
        return 1
    print(f"PASS golden: all {W * H} pixels match the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
