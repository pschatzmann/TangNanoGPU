# Test clips

H.264 Baseline/CAVLC clips generated with ffmpeg from its built-in test
sources, so they carry no third-party content. Each is 30 frames at 10 fps:
SMPTE colour bars with two moving boxes. Most of each picture is static,
so most P-frame macroblocks are unchanged.

| File | Used by |
|---|---|
| `test_320x240.264` | `tools/golden` video test (TinyH264 decode → `YUVFrameWriter` → emulator / RTL) |
| `test_256x192.264` | `examples/video-player` (embedded as `clip.h`) |

```bash
ffmpeg -f lavfi -i "smptebars=size=320x240:rate=10:duration=3" \
  -f lavfi -i "color=c=yellow:size=48x40:rate=10" \
  -f lavfi -i "color=c=red:size=24x24:rate=10" \
  -filter_complex "[0][1]overlay=x='20+mod(t*120\,240)':y=150:shortest=1[a];[a][2]overlay=x=136:y='10+mod(t*80\,100)':shortest=1" \
  -c:v libx264 -profile:v baseline -coder 0 -pix_fmt yuv420p -g 30 -bf 0 \
  -x264-params cabac=0:ref=1 test_320x240.264

ffmpeg -f lavfi -i "smptebars=size=256x192:rate=10:duration=3" \
  -f lavfi -i "color=c=yellow:size=40x32:rate=10" \
  -f lavfi -i "color=c=red:size=20x20:rate=10" \
  -filter_complex "[0][1]overlay=x='16+mod(t*96\,192)':y=120:shortest=1[a];[a][2]overlay=x=108:y='8+mod(t*64\,80)':shortest=1" \
  -c:v libx264 -profile:v baseline -coder 0 -pix_fmt yuv420p -g 30 -bf 0 \
  -x264-params cabac=0:ref=1 test_256x192.264
```

`overlay` is used for the motion because `drawbox` evaluates its position
only once in the ffmpeg version used here.
