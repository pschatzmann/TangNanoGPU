#pragma once
#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "TinyGPU.h"
#include "TangNanoGPU/GPUDevice.h"

namespace tangnanogpu {

using tinygpu::IFont;
using tinygpu::ISurface;
using tinygpu::RGB565;

/**
 * @brief TinyGPU surface whose pixels live in the Tang Nano 20K's
 * framebuffer: every drawing call is sent to the FPGA as a command and
 * rendered there, while the board keeps refreshing HDMI in the background.
 *
 * Drop-in for a Surface<RGB565> of 320x240 in code that draws through
 * ISurface<RGB565> (primitives, text, sprites, WireFrame3D, CartesianView,
 * TinyMaterialDesign ...). The FPGA reproduces TinyGPU's own line, circle
 * and fill algorithms, so the output is pixel-identical.
 *
 * Differences to an in-memory surface:
 * - data() returns nullptr and size() 0: there is no local pixel buffer.
 *   getPixel()/copySprite() work, but read back over SPI (slow).
 * - Text is rendered by the host font into a 1/2-bit mask and drawn by the
 *   FPGA in one command per text call, so any IFont works.
 * - Drawing is asynchronous; call gpu().flush() to wait for completion.
 * - Double buffering: setTarget()/show()/swap().
 */
class SurfaceTangNano : public ISurface<RGB565> {
 public:
  explicit SurfaceTangNano(TangNanoGPU& gpu, IFont<RGB565>& font = tinygpu::FontRGB565)
      : gpu_(gpu), font_(&font) {}

  bool begin() override {
    clipStack_.clear();
    gpu_.resetClip();
    return true;
  }
  void end() override { gpu_.flushPixels(); }

  /// The framebuffer size is fixed by the gateware.
  bool resize(size_t newWidth, size_t newHeight) override {
    return newWidth == kWidth && newHeight == kHeight;
  }

  size_t width() const override { return kWidth; }
  size_t height() const override { return kHeight; }

  void setFont(IFont<RGB565>& font) { font_ = &font; }
  IFont<RGB565>& font() override { return *font_; }

  const uint8_t* data() const override { return nullptr; }
  size_t size() const override { return 0; }

  // ---------------- pixels ----------------

  void setPixel(size_t x, size_t y, RGB565 color) override {
    if (capture_) {
      captureRect(sx(x), sx(y), 1, 1, color);
      return;
    }
    gpu_.pixel(sx(x), sx(y), color.getValue());
  }

  RGB565 getPixel(size_t x, size_t y) const override {
    if (x >= kWidth || y >= kHeight) return RGB565();
    // row-cached: a getPixel/setPixel loop reads each row over SPI once
    return RGB565(const_cast<TangNanoGPU&>(gpu_).readPixel(static_cast<int>(x), static_cast<int>(y)));
  }

  // ---------------- primitives ----------------

  /// TinyGPU's clear() ignores the clip rect.
  void clear(RGB565 color = RGB565()) override {
    gpu_.resetClip();
    gpu_.fillRect(0, 0, kWidth, kHeight, color.getValue());
    applyClip();
  }

  /// TinyGPU semantics: new(x, y) = old(x + dx, y + dy), black where the
  /// source is outside the surface; ignores the clip rect.
  void scroll(int dx, int dy) override {
    if (dx == 0 && dy == 0) return;
    gpu_.resetClip();
    int adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
    if (adx < kWidth && ady < kHeight) {
      gpu_.copyRect(kFrameBufferRow[gpu_.target()], dx > 0 ? dx : 0, dy > 0 ? dy : 0,
                    kWidth - adx, kHeight - ady, dx < 0 ? -dx : 0, dy < 0 ? -dy : 0);
    }
    if (dx > 0) gpu_.fillRect(kWidth - dx, 0, dx, kHeight, 0);
    if (dx < 0) gpu_.fillRect(0, 0, -dx, kHeight, 0);
    if (dy > 0) gpu_.fillRect(0, kHeight - dy, kWidth, dy, 0);
    if (dy < 0) gpu_.fillRect(0, 0, kWidth, -dy, 0);
    applyClip();
  }

  void drawLine(size_t x0, size_t y0, size_t x1, size_t y1, RGB565 color) override {
    gpu_.line(sx(x0), sx(y0), sx(x1), sx(y1), color.getValue());
  }

  /// Same four lines as TinyGPU's SurfaceBase::drawRect().
  void drawRect(size_t x, size_t y, size_t w, size_t h, RGB565 color) override {
    if (w == 0 || h == 0) return;
    size_t x1 = x + w - 1, y1 = y + h - 1;
    drawLine(x, y, x1, y, color);
    drawLine(x, y1, x1, y1, color);
    drawLine(x, y, x, y1, color);
    drawLine(x1, y, x1, y1, color);
  }

  void fillRect(size_t x, size_t y, size_t w, size_t h, RGB565 color) override {
    if (w == 0 || h == 0) return;
    if (capture_) {
      captureRect(sx(x), sx(y), static_cast<int>(w), static_cast<int>(h), color);
      return;
    }
    gpu_.fillRect(sx(x), sx(y), static_cast<int>(w), static_cast<int>(h), color.getValue());
  }

  void drawCircle(size_t x, size_t y, size_t r, RGB565 color) override {
    gpu_.circle(sx(x), sx(y), static_cast<int>(r), color.getValue(), false);
  }

  void fillCircle(size_t x, size_t y, size_t r, RGB565 color) override {
    gpu_.circle(sx(x), sx(y), static_cast<int>(r), color.getValue(), true);
  }

  // ---------------- sprites ----------------

  /// Draws `sprite` at (x, y), skipping pixels equal to invisibleColor.
  void drawSprite(size_t x, size_t y, const ISurface<RGB565>& sprite,
                  RGB565 invisibleColor = RGB565()) override {
    writeSurface(sx(x), sx(y), sprite, true, invisibleColor.getValue());
  }

  /// Fills the area a sprite at (x, y) covers (clipped, like TinyGPU).
  void clearSprite(size_t x, size_t y, ISurface<RGB565>& sprite,
                   RGB565 clearColor = RGB565()) override {
    fillRect(x, y, sprite.width(), sprite.height(), clearColor);
  }

  /// Copies the framebuffer area at (x, y) into `sprite` (pixels outside
  /// the framebuffer become 0), like TinyGPU. Reads back over SPI.
  void copySprite(size_t x, size_t y, const ISurface<RGB565>& sprite) override {
    ISurface<RGB565>& dst = const_cast<ISurface<RGB565>&>(sprite);
    const int w = static_cast<int>(sprite.width()), h = static_cast<int>(sprite.height());
    const int x0 = sx(x), y0 = sx(y);
    std::vector<uint8_t> row(static_cast<size_t>(w) * 2);
    for (int r = 0; r < h; ++r) {
      for (int i = 0; i < w; ++i) dst.setPixel(i, r, RGB565());
      int fy = y0 + r;
      if (fy < 0 || fy >= kHeight) continue;
      int fx0 = x0 < 0 ? 0 : x0;
      int fx1 = (x0 + w > kWidth) ? kWidth : x0 + w;
      if (fx1 <= fx0) continue;
      gpu_.readRect(fx0, fy, fx1 - fx0, 1, row.data());
      for (int fx = fx0; fx < fx1; ++fx) {
        size_t k = static_cast<size_t>(fx - fx0) * 2;
        dst.setPixel(fx - x0, r, RGB565(static_cast<uint16_t>(row[k] | (row[k + 1] << 8))));
      }
    }
  }

  /// Writes a whole surface to (x, y) without colour key (used by
  /// DisplayDriverTangNano).
  void writeSurface(int x, int y, const ISurface<RGB565>& src, bool useKey = false,
                    uint16_t key = 0) {
    const int w = static_cast<int>(src.width()), h = static_cast<int>(src.height());
    if (w == 0 || h == 0) return;
    const uint8_t* d = src.data();
    if (d != nullptr && src.size() >= static_cast<size_t>(w) * h * 2) {
      gpu_.writeRect(x, y, w, h, d, 0, useKey, key);
      return;
    }
    // no contiguous buffer: go through getPixel() row by row
    std::vector<uint8_t> row(static_cast<size_t>(w) * 2);
    for (int r = 0; r < h; ++r) {
      for (int i = 0; i < w; ++i) {
        uint16_t v = src.getPixel(i, r).getValue();
        row[i * 2] = v & 0xff;
        row[i * 2 + 1] = v >> 8;
      }
      gpu_.writeRect(x, y + r, w, 1, row.data(), 0, useKey, key);
    }
  }

  // ---------------- text ----------------

  /// Renders the text with the host font into a mask (fg / bg / untouched
  /// per pixel) and sends it as one MASK command, so the result is
  /// identical to drawing the text into a Surface<RGB565>.
  void drawText(int16_t x, int16_t y, const char* text, RGB565 foreground,
                RGB565 background = RGB565(), bool opaque = false, uint8_t scale = 1,
                uint8_t spacing = 1, uint8_t lineSpacing = 1) override {
    if (text == nullptr || *text == 0) return;
    if (scale == 0) scale = 1;
    const int w = static_cast<int>(font_->measureTextWidth(text, scale, spacing));
    const int h = static_cast<int>(font_->measureTextHeight(text, scale, lineSpacing));
    const bool twoBpp = opaque;
    const size_t rowBytes = (static_cast<size_t>(w) * (twoBpp ? 2 : 1) + 7) / 8;
    if (w <= 0 || h <= 0 || rowBytes * h > kMaxMaskBytes) {
      // too big for one mask: let the font issue FILL_RECTs directly
      font_->drawText(*this, x, y, text, foreground, background, opaque, scale, spacing,
                      lineSpacing);
      return;
    }
    mask_.assign(rowBytes * h, 0);
    capture_ = true;
    capX_ = x;
    capY_ = y;
    capW_ = w;
    capH_ = h;
    capRowBytes_ = rowBytes;
    capTwoBpp_ = twoBpp;
    capFg_ = foreground.getValue();
    capBg_ = background.getValue();
    font_->drawText(*this, x, y, text, foreground, background, opaque, scale, spacing,
                    lineSpacing);
    capture_ = false;
    gpu_.mask(x, y, w, h, twoBpp, capFg_, capBg_, mask_.data());
  }

  // ---------------- clipping (TinyGPU semantics) ----------------

  bool contains(size_t x, size_t y) override {
    return x < kWidth && y < kHeight && isClipVisible(x, y);
  }

  void pushClipRect(size_t x, size_t y, size_t w, size_t h) override {
    Clip c{x, y, w, h};
    if (!clipStack_.empty()) c = intersect(c, clipStack_.back());
    clipStack_.push_back(c);
    applyClip();
  }

  void popClipRect() override {
    if (!clipStack_.empty()) clipStack_.pop_back();
    applyClip();
  }

  bool isClipVisible(size_t x, size_t y) const override {
    if (clipStack_.empty()) return true;
    const Clip& c = clipStack_.back();
    return x >= c.x && y >= c.y && x < c.x + c.w && y < c.y + c.h;
  }

  // ---------------- double buffering ----------------

  /// Draw into framebuffer 0 or 1.
  void setTarget(uint8_t buffer) { gpu_.setTarget(buffer); }
  /// Show framebuffer 0 or 1 (switches at the next frame).
  void show(uint8_t buffer) { gpu_.show(buffer); }
  /// Shows the buffer just drawn and continues drawing into the other one;
  /// drawing waits for the switch, so the visible buffer is never touched.
  void swap() {
    uint8_t drawn = gpu_.target();
    gpu_.show(drawn);
    gpu_.setTarget(drawn ^ 1);
    gpu_.waitVSync();
  }

  TangNanoGPU& gpu() { return gpu_; }

 protected:
  struct Clip {
    size_t x, y, w, h;
  };
  static constexpr size_t kMaxMaskBytes = 8192;

  TangNanoGPU& gpu_;
  IFont<RGB565>* font_;
  std::vector<Clip> clipStack_;

  bool capture_ = false;
  int capX_ = 0, capY_ = 0, capW_ = 0, capH_ = 0;
  size_t capRowBytes_ = 0;
  bool capTwoBpp_ = false;
  uint16_t capFg_ = 0, capBg_ = 0;
  std::vector<uint8_t> mask_;

  /// size_t coordinate -> signed int, the way TinyGPU's own (int) casts
  /// read wrapped "negative" coordinates.
  static int sx(size_t v) { return static_cast<int>(static_cast<int16_t>(v)); }

  static Clip intersect(const Clip& a, const Clip& b) {
    size_t x0 = a.x > b.x ? a.x : b.x;
    size_t y0 = a.y > b.y ? a.y : b.y;
    size_t x1 = (a.x + a.w) < (b.x + b.w) ? (a.x + a.w) : (b.x + b.w);
    size_t y1 = (a.y + a.h) < (b.y + b.h) ? (a.y + a.h) : (b.y + b.h);
    if (x1 <= x0 || y1 <= y0) return Clip{x0, y0, 0, 0};
    return Clip{x0, y0, x1 - x0, y1 - y0};
  }

  void applyClip() {
    if (clipStack_.empty()) {
      gpu_.resetClip();
    } else {
      const Clip& c = clipStack_.back();
      int w = c.w > 0xffff ? 0xffff : static_cast<int>(c.w);
      int h = c.h > 0xffff ? 0xffff : static_cast<int>(c.h);
      gpu_.setClip(c.x > 0x7fff ? 0x7fff : static_cast<int>(c.x),
                   c.y > 0x7fff ? 0x7fff : static_cast<int>(c.y), w, h);
    }
  }

  /// Records a fill of colour `color` into the text mask.
  void captureRect(int x, int y, int w, int h, RGB565 color) {
    const uint8_t code = (color.getValue() == capFg_) ? 1 : 2;  // 2bpp: 01 fg, 10 bg
    for (int yy = y; yy < y + h; ++yy) {
      int my = yy - capY_;
      for (int xx = x; xx < x + w; ++xx) {
        int mx = xx - capX_;
        if (mx < 0 || my < 0 || mx >= capW_ || my >= capH_) {
          // outside the measured box (unexpected font metrics): draw directly
          gpu_.fillRect(xx, yy, 1, 1, color.getValue());
          continue;
        }
        uint8_t* row = mask_.data() + static_cast<size_t>(my) * capRowBytes_;
        if (capTwoBpp_) {
          int shift = 6 - (mx % 4) * 2;
          row[mx / 4] = static_cast<uint8_t>((row[mx / 4] & ~(3 << shift)) | (code << shift));
        } else if (code == 1) {
          row[mx / 8] |= static_cast<uint8_t>(0x80 >> (mx % 8));
        }
      }
    }
  }
};

}  // namespace tangnanogpu
