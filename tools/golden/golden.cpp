// Golden-model generator for the TangNanoGPU gateware.
//
// Renders one test scene twice:
//   1. with TinyGPU's software Surface<RGB565>      -> expected.hex
//   2. with SurfaceTangNano over a recording transport -> cmds.txt
//      (the exact SPI transactions the Arduino library would send)
//
// gateware/tb/tb_top.v replays cmds.txt into the real RTL and dumps the
// SDRAM framebuffer; compare.py then requires it to match expected.hex
// pixel for pixel. See tools/golden/run_golden.sh.
//
// Usage: golden <out-dir>

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <string>

#include "TinyGPU.h"
#include "TangNanoGPU.h"
#include "Emulator.h"
#if __has_include("TinyMaterialDesign.h")
#include "TinyMaterialDesign.h"
#define HAVE_TINYMD 1
#endif

using namespace tinygpu;
using namespace tangnanogpu;

static const int W = kWidth, H = kHeight;

// A 16x16 test sprite: diagonal stripes on a transparent (key = 0) disc.
static void makeSprite(Surface<RGB565>& spr) {
  spr.begin();
  for (int y = 0; y < 16; ++y)
    for (int x = 0; x < 16; ++x) {
      int dx = x - 8, dy = y - 8;
      bool inside = dx * dx + dy * dy < 56;
      RGB565 c = ((x + y) & 4) ? RGB565(255, 128, 0) : RGB565(0, 200, 255);
      spr.setPixel(x, y, inside ? c : RGB565());
    }
}

// The scene. `gpu` is set when drawing through SurfaceTangNano, so the
// hardware-only blit path can be used where software uses drawSprite().
static void scene(ISurface<RGB565>& s, TangNanoGPU* gpu) {
  s.begin();
  s.clear(RGB565(16, 16, 48));

  // rectangles, including ones clipped by the right/bottom screen edge
  s.fillRect(5, 5, 60, 40, RGB565(255, 0, 0));
  s.fillRect(300, 200, 50, 80, RGB565(0, 255, 0));
  s.fillRect(0, 0, 1, 1, RGB565(255, 255, 255));
  s.drawRect(70, 5, 61, 41, RGB565(255, 255, 0));
  s.fillRect(71, 6, 3, 39, RGB565(0, 0, 255));  // odd x and odd width

  // lines in every octant, plus axis-parallel and degenerate ones
  for (int i = 0; i < 24; ++i) {
    double a = i * (2 * M_PI / 24) + 0.1;
    int x1 = 160 + static_cast<int>(lround(100 * cos(a)));
    int y1 = 120 + static_cast<int>(lround(95 * sin(a)));
    s.drawLine(160, 120, x1, y1, RGB565(40 + i * 8, 255 - i * 8, 128));
  }
  s.drawLine(0, 0, 319, 239, RGB565(255, 255, 255));
  s.drawLine(319, 0, 0, 239, RGB565(200, 200, 200));
  s.drawLine(10, 50, 300, 50, RGB565(255, 0, 255));
  s.drawLine(310, 10, 310, 230, RGB565(0, 255, 255));
  s.drawLine(150, 150, 150, 150, RGB565(255, 255, 255));
  s.drawLine(0, 239, 400, 239, RGB565(255, 128, 0));  // runs off the right edge

  // circles (outline / filled), clipped at every edge
  s.drawCircle(60, 180, 40, RGB565(255, 255, 0));
  s.fillCircle(260, 60, 30, RGB565(0, 128, 255));
  s.fillCircle(10, 230, 25, RGB565(255, 0, 128));
  s.drawCircle(318, 2, 20, RGB565(128, 255, 128));
  s.drawCircle(100, 100, 0, RGB565(255, 255, 255));
  s.fillCircle(160, 5, 12, RGB565(64, 255, 64));

  // ISurface default helpers (built on drawLine/fillRect/setPixel)
  s.drawRoundRect(140, 150, 80, 50, 12, RGB565(255, 200, 200));
  s.fillRoundRect(230, 150, 70, 40, 10, RGB565(100, 50, 200));
  s.drawArc(100, 100, 30, 10.0f, 280.0f, RGB565(255, 255, 255), 3);

  // text: transparent, opaque, scaled, multi-line
  s.drawText(8, 60, "Hello TangNanoGPU!", RGB565(255, 255, 255));
  s.drawText(8, 72, "Opaque\nMulti-line", RGB565(255, 255, 0), RGB565(0, 0, 160), true, 2, 1, 2);
  s.drawText(250, 225, "edge text", RGB565(255, 255, 255), RGB565(255, 0, 0), true, 1, 2, 1);

  // clipping: nested clip rects
  s.pushClipRect(200, 90, 60, 40);
  s.fillCircle(230, 110, 40, RGB565(255, 0, 255));
  s.pushClipRect(190, 80, 40, 100);
  s.drawLine(190, 80, 280, 140, RGB565(255, 255, 255));
  s.drawText(195, 100, "clipped", RGB565(0, 0, 0), RGB565(255, 255, 255), true, 1, 1, 1);
  s.popClipRect();
  s.fillRect(150, 85, 200, 6, RGB565(0, 255, 0));
  s.popClipRect();

  // single pixels
  for (int i = 0; i < 150; ++i)
    s.setPixel((i * 37) % W, 200 + (i % 9), RGB565(i * 3, 255 - i, i));

  // row-by-row setPixel loops (sent as WRITE_RECT runs), crossing a clip
  // rect, plus every-other-pixel rows (short runs -> PIXELS batches)
  s.pushClipRect(100, 150, 120, 30);
  for (int y = 140; y < 190; ++y)
    for (int x = 90; x < 230; ++x) s.setPixel(x, y, RGB565(x, y, (x + y) & 255));
  s.popClipRect();
  for (int y = 192; y < 196; ++y)
    for (int x = 0; x < W; x += 2) s.setPixel(x, y, RGB565(255, x & 255, 0));

  // sprites with colour key (0 = transparent)
  Surface<RGB565> spr(16, 16, FontRGB565);
  makeSprite(spr);
  s.drawSprite(20, 120, spr, RGB565());
  s.drawSprite(312, 20, spr, RGB565());  // half off-screen
  if (gpu) {
    gpu->uploadImage(kImageRowBase, 16, 16, spr.data());
    gpu->blit(kImageRowBase, 16, 16, 41, 121, true, 0);
    gpu->blit(kImageRowBase, 16, 16, 63, 120, false, 0);
  } else {
    s.drawSprite(41, 121, spr, RGB565());
    for (int y = 0; y < 16; ++y)
      for (int x = 0; x < 16; ++x) s.setPixel(63 + x, 120 + y, spr.getPixel(x, y));
  }

  // whole-screen scroll (copy inside the framebuffer + black fill)
  s.scroll(3, -2);

  // a 3D wireframe cube (per-pixel drawing through setPixel)
  WireFrame3D<RGB565> wf(s);
  wf.begin();
  wf.setPerspective(60.0f, 0.1f, 100.0f);
  WireFrame3D<RGB565>::Camera cam;
  cam.position = {0.0f, 0.0f, 5.0f};
  cam.target = {0.0f, 0.0f, 0.0f};
  cam.up = {0.0f, 1.0f, 0.0f};
  wf.setCamera(cam);
  auto cube = WireFrame3D<RGB565>::cube(2.0f);
  auto model = WireFrame3D<RGB565>::rotationY(0.6f) * WireFrame3D<RGB565>::rotationX(0.4f);
  wf.renderWireframe(s, cube, model, RGB565(255, 255, 255));
  // (no s.end(): Surface::end() frees the software surface's buffer)
}

#ifdef HAVE_TINYMD
// TinyMaterialDesign scene with a presented dialog: its scrim reads every
// pixel back (getPixel/setPixel), so it is recorded with the emulator
// transport, which answers READ_DATA. See docs/tinymaterialdesign.md.
static int tmdGolden(const std::string& dir) {
  using namespace tinymd;
  static Screen<RGB565> screen(defaultTheme<RGB565>());
  static AppBar<RGB565> appBar(Bounds(0, 0, 320, 48), "TangNanoGPU");
  static Label<RGB565> label(Bounds(16, 54, 288, 20), "TinyMaterialDesign on HDMI");
  static Switch<RGB565> toggle(Bounds(16, 82, 48, 28));
  static Checkbox<RGB565> check(Bounds(196, 84, 24, 24), true);
  static Slider<RGB565> slider(Bounds(16, 122, 288, 28), 0.0f, 100.0f, 40.0f);
  static LinearProgressIndicator<RGB565> progress(Bounds(16, 160, 288, 8), 0.4f);
  static Button<RGB565> button(Bounds(16, 184, 150, 40), "Open dialog");
  static CircularProgressIndicator<RGB565> spinner(Bounds(262, 180, 44, 44), 0.65f);
  static Dialog<RGB565> dialog(Bounds(30, 50, 260, 140), "Hello HDMI",
                               "This dialog and its scrim are drawn by the FPGA.");
  static Button<RGB565> ok(Bounds(0, 0, 80, 36), "OK");
  screen.addFixedWidget(appBar);
  screen.addWidget(label);
  screen.addWidget(toggle);
  screen.addWidget(check);
  screen.addWidget(slider);
  screen.addWidget(progress);
  screen.addWidget(button);
  screen.addWidget(spinner);
  ok.bounds = dialog.actionRect(0, 1);
  dialog.addAction(ok);
  screen.presentDialog(dialog);

  Surface<RGB565> ref(W, H, FontRGB565);
  ref.begin();
  screen.draw(ref);

  TransportEmulator emu;
  TangNanoGPU gpu(emu);
  SurfaceTangNano hw(gpu);
  hw.begin();
  screen.invalidate();
  screen.draw(hw);
  gpu.flushPixels();

  FILE* f = fopen((dir + "/expected_tmd.hex").c_str(), "w");
  if (!f) return 1;
  int diffs = 0;
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) {
      uint16_t e = ref.getPixel(x, y).getValueSwapped();
      fprintf(f, "%04x\n", e);
      if (emu.pixel(0, x, y) != e) ++diffs;
    }
  fclose(f);

  f = fopen((dir + "/cmds_tmd.txt").c_str(), "w");
  if (!f) return 1;
  size_t reads = 0;
  for (const auto& r : emu.records()) {
    fprintf(f, "%x", static_cast<unsigned>(r.mosi.size()));
    for (uint8_t b : r.mosi) fprintf(f, " %02x", b);
    fprintf(f, "\n");
    if (r.mosi.size() >= 2 && r.mosi[1] == op::kReadData) {
      // expected MISO bytes for the RTL replay to check
      fprintf(f, "fffffff %x", static_cast<unsigned>(r.miso.size()));
      for (uint8_t b : r.miso) fprintf(f, " %02x", b);
      fprintf(f, "\n");
      ++reads;
    }
  }
  fclose(f);
  printf("golden tmd: %zu transactions (%zu readbacks); host emulation %s (%d pixels differ)\n",
         emu.records().size(), reads, diffs ? "FAIL" : "PASS", diffs);
  return diffs ? 1 : 0;
}
#endif

int main(int argc, char** argv) {
  std::string dir = argc > 1 ? argv[1] : ".";

  // 1. software reference
  Surface<RGB565> ref(W, H, FontRGB565);
  ref.begin();
  scene(ref, nullptr);
  FILE* f = fopen((dir + "/expected.hex").c_str(), "w");
  if (!f) return 1;
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) fprintf(f, "%04x\n", ref.getPixel(x, y).getValueSwapped());
  fclose(f);

  // 2. command stream
  TransportRecorder rec;
  TangNanoGPU gpu(rec);
  SurfaceTangNano hw(gpu);
  scene(hw, &gpu);
  gpu.flushPixels();
  f = fopen((dir + "/cmds.txt").c_str(), "w");
  if (!f) return 1;
  size_t bytes = 0;
  for (const auto& t : rec.transactions()) {
    fprintf(f, "%x", static_cast<unsigned>(t.size()));
    for (uint8_t b : t) fprintf(f, " %02x", b);
    fprintf(f, "\n");
    bytes += t.size();
  }
  fclose(f);
  printf("golden: %zu transactions, %zu bytes\n", rec.transactions().size(), bytes);
#ifdef HAVE_TINYMD
  return tmdGolden(dir);
#else
  printf("golden tmd: skipped (TinyMaterialDesign not found)\n");
  return 0;
#endif
}
