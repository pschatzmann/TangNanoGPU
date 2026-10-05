#pragma once
// Software model of the TangNanoGPU protocol (docs/protocol.md), used as a
// transport by the golden tool so host code that reads back pixels (e.g.
// TinyMaterialDesign's dialog scrim, via getPixel()) can be recorded too.
//
// It executes every command on an SDRAM-row model with the gateware's
// semantics (signed coordinates, inclusive clip, TinyGPU's Bresenham and
// midpoint algorithms), records each transaction, and answers PING /
// STATUS / READ_DATA. The RTL replay (gateware/tb/tb_top.v) checks that the
// real gateware returns the same READ_DATA bytes and the same framebuffer.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <array>
#include <deque>
#include <map>
#include <vector>

#include "TangNanoGPU/Protocol.h"
#include "TangNanoGPU/Transport.h"

namespace tangnanogpu {

class TransportEmulator : public ITransport {
 public:
  struct Record {
    std::vector<uint8_t> mosi;  ///< bytes sent (reads: zeros after the opcode)
    std::vector<uint8_t> miso;  ///< READ_DATA only: bytes returned after the opcode
  };

  TransportEmulator() { reset(); }

  void beginTransaction(bool) override {
    cur_.clear();
    reply_.clear();
    replyPos_ = 0;
    replied_ = false;
  }
  void write(const uint8_t* d, size_t n) override { cur_.insert(cur_.end(), d, d + n); }
  void read(uint8_t* d, size_t n) override {
    if (!replied_) makeReply();
    for (size_t i = 0; i < n; ++i) {
      d[i] = replyPos_ < reply_.size() ? reply_[replyPos_] : 0;
      ++replyPos_;
      cur_.push_back(0);
    }
  }
  void endTransaction() override {
    Record r;
    r.mosi = cur_;
    if (cur_.size() >= 2 && cur_[1] == op::kReadData) {
      r.miso.assign(reply_.begin(), reply_.begin() + std::min(replyPos_, reply_.size()));
    }
    records_.push_back(r);
    if (cur_.size() >= 2 && !isImmediate(cur_[1])) execute(cur_);
    if (cur_.size() >= 2 && cur_[1] == op::kReset) reset();
  }
  bool hasBusyPin() const override { return true; }
  uint32_t millis() override { return ++fakeMillis_; }
  void delayMicros(uint32_t) override {}

  const std::vector<Record>& records() const { return records_; }

  /// Native RGB565 value of framebuffer `b` at (x, y).
  uint16_t pixel(int b, int x, int y) { return toNative(row(kFrameBufferRow[b] + y)[x]); }

 protected:
  std::map<int, std::array<uint16_t, 512>> rows_;  // stored values (wire order)
  std::vector<uint8_t> cur_, reply_;
  size_t replyPos_ = 0;
  bool replied_ = false;
  std::deque<uint8_t> resp_;
  std::vector<Record> records_;
  uint32_t fakeMillis_ = 0;
  int target_ = 0;
  int cx0_, cx1_, cy0_, cy1_;  // inclusive clip

  static bool isImmediate(uint8_t o) {
    return o == op::kPing || o == op::kReset || o == op::kStatus || o == op::kReadData;
  }
  // stored value: low byte = high byte of the native colour (wire order)
  static uint16_t toNative(uint16_t v) { return static_cast<uint16_t>((v << 8) | (v >> 8)); }

  std::array<uint16_t, 512>& row(int r) {
    auto it = rows_.find(r);
    if (it == rows_.end()) it = rows_.emplace(r, std::array<uint16_t, 512>{}).first;
    return it->second;
  }

  void reset() {
    resp_.clear();
    target_ = 0;
    cx0_ = 0; cx1_ = kWidth - 1; cy0_ = 0; cy1_ = kHeight - 1;
  }

  void makeReply() {
    replied_ = true;
    if (cur_.size() < 2) return;
    switch (cur_[1]) {
      case op::kPing: reply_ = {'T', 'A', 'N', 'G', 1}; break;
      case op::kStatus: {
        uint16_t used = static_cast<uint16_t>(resp_.size());
        reply_ = {0xff, 0x0f, gpuflag::kSdramReady, 0, 0,
                  static_cast<uint8_t>(used & 0xff), static_cast<uint8_t>(used >> 8)};
        break;
      }
      case op::kReadData:
        reply_.assign(resp_.begin(), resp_.end());
        resp_.clear();
        break;
      default: break;
    }
  }

  // ---- command execution ----
  struct Reader {
    const std::vector<uint8_t>& b;
    size_t p = 2;
    uint8_t u8() { return p < b.size() ? b[p++] : 0; }
    int u16() { int v = u8(); return v | (u8() << 8); }
    int i16() { return static_cast<int16_t>(u16()); }
    uint16_t color() { int lo = u8(); return static_cast<uint16_t>(lo | (u8() << 8)); }
    void bytes(uint8_t* dst, size_t n) {
      size_t avail = p < b.size() ? b.size() - p : 0, k = n < avail ? n : avail;
      if (k) memcpy(dst, b.data() + p, k);
      if (n > k) memset(dst + k, 0, n - k);
      p += n;
    }
  };

  void put(int x, int y, uint16_t c, bool clip = true) {
    int x0 = clip ? cx0_ : 0, x1 = clip ? cx1_ : kWidth - 1;
    int y0 = clip ? cy0_ : 0, y1 = clip ? cy1_ : kHeight - 1;
    if (x < x0 || x > x1 || y < y0 || y > y1) return;
    row(kFrameBufferRow[target_] + y)[x] = c;
  }

  void execute(const std::vector<uint8_t>& b) {
    Reader r{b};
    switch (b[1]) {
      case op::kSetTarget: target_ = r.u8() & 1; break;
      case op::kShow: case op::kWaitVSync: break;
      case op::kSetClip: {
        int x = r.i16(), y = r.i16(), w = r.u16(), h = r.u16();
        if (w == 0 || h == 0) { cx0_ = cy0_ = 1; cx1_ = cy1_ = 0; break; }
        cx0_ = std::max(x, 0); cx1_ = std::min(x + w - 1, kWidth - 1);
        cy0_ = std::max(y, 0); cy1_ = std::min(y + h - 1, kHeight - 1);
        break;
      }
      case op::kFillRect: {
        int x = r.i16(), y = r.i16(), w = r.u16(), h = r.u16();
        uint16_t c = r.color();
        for (int yy = y; yy < y + h; ++yy)
          for (int xx = x; xx < x + w; ++xx) put(xx, yy, c);
        break;
      }
      case op::kLine: {
        int x0 = r.i16(), y0 = r.i16(), x1 = r.i16(), y1 = r.i16();
        uint16_t c = r.color();
        int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
        int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
        int err = dx + dy;
        while (true) {
          put(x0, y0, c);
          if (x0 == x1 && y0 == y1) break;
          int e2 = 2 * err;
          if (e2 >= dy) { err += dy; x0 += sx; }
          if (e2 <= dx) { err += dx; y0 += sy; }
        }
        break;
      }
      case op::kPixels: {
        int n = r.u16();
        for (int i = 0; i < n; ++i) {
          int x = r.i16(), y = r.i16();
          put(x, y, r.color(), false);
        }
        break;
      }
      case op::kCircle: {
        int cx = r.i16(), cy = r.i16(), rad = r.u16();
        uint16_t c = r.color();
        bool fill = r.u8() & 1;
        int ox = rad, oy = 0, d = 1 - rad;
        while (ox >= oy) {
          if (fill) {
            span(cx - ox, cx + ox, cy + oy, c); span(cx - ox, cx + ox, cy - oy, c);
            span(cx - oy, cx + oy, cy + ox, c); span(cx - oy, cx + oy, cy - ox, c);
          } else {
            put(cx + ox, cy + oy, c); put(cx + oy, cy + ox, c); put(cx - oy, cy + ox, c);
            put(cx - ox, cy + oy, c); put(cx - ox, cy - oy, c); put(cx - oy, cy - ox, c);
            put(cx + oy, cy - ox, c); put(cx + ox, cy - oy, c);
          }
          ++oy;
          if (d <= 0) d += 2 * oy + 1;
          else { --ox; d += 2 * (oy - ox) + 1; }
        }
        break;
      }
      case op::kWriteRect: {
        int x = r.i16(), y = r.i16(), w = r.u16(), h = r.u16();
        int flags = r.u8();
        uint16_t key = r.color();
        for (int j = 0; j < h; ++j)
          for (int i = 0; i < w; ++i) {
            uint16_t c = r.color();
            if ((flags & 1) && c == key) continue;
            put(x + i, y + j, c, !(flags & 2));
          }
        break;
      }
      case op::kUpload: {
        int base = r.u16(), w = r.u16(), h = r.u16();
        for (int j = 0; j < h; ++j)
          for (int i = 0; i < w; ++i) row(base + j)[i] = r.color();
        break;
      }
      case op::kCopyRect: {
        int srow = r.u16(), sx = r.u16(), sy = r.u16(), w = r.u16(), h = r.u16();
        int dx = r.i16(), dy = r.i16(), flags = r.u8();
        uint16_t key = r.color();
        std::vector<uint16_t> tmp(static_cast<size_t>(w) * h);
        for (int j = 0; j < h; ++j)
          for (int i = 0; i < w; ++i) tmp[j * w + i] = row(srow + sy + j)[(sx + i) & 511];
        for (int j = 0; j < h; ++j)
          for (int i = 0; i < w; ++i) {
            uint16_t c = tmp[j * w + i];
            if (!((flags & 1) && c == key)) put(dx + i, dy + j, c);
          }
        break;
      }
      case op::kMask: {
        int x = r.i16(), y = r.i16(), w = r.u16(), h = r.u16();
        bool two = r.u8() & 1;
        uint16_t fg = r.color(), bg = r.color();
        for (int j = 0; j < h; ++j) {
          int bits = 0, have = 0;
          for (int i = 0; i < w; ++i) {
            if (have == 0) { bits = r.u8(); have = 8; }
            if (two) {
              int v = (bits >> 6) & 3;
              bits <<= 2; have -= 2;
              if (v == 1) put(x + i, y + j, fg);
              else if (v == 2) put(x + i, y + j, bg);
            } else {
              int v = (bits >> 7) & 1;
              bits <<= 1; have -= 1;
              if (v) put(x + i, y + j, fg);
            }
          }
        }
        break;
      }
      case op::kYuvMacroblocks: {
        int n = r.u16();
        for (int m = 0; m < n; ++m) {
          int x = r.i16(), y = r.i16();
          uint8_t cb[64], cr[64];
          r.bytes(cb, 64);
          r.bytes(cr, 64);
          for (int j = 0; j < 16; ++j)
            for (int i = 0; i < 16; ++i) {
              int k = (j / 2) * 8 + i / 2;
              put(x + i, y + j, yuvToStored(r.u8(), cb[k], cr[k]));
            }
        }
        break;
      }
      case op::kReadRect: {
        int x = r.u16(), y = r.u16(), w = r.u16(), h = r.u16();
        for (int j = 0; j < h; ++j)
          for (int i = 0; i < w; ++i) {
            uint16_t v = row(kFrameBufferRow[target_] + y + j)[(x + i) & 511];
            resp_.push_back(v & 0xff);
            resp_.push_back(v >> 8);
          }
        break;
      }
      default: break;
    }
  }

 public:
  /// BT.601 limited range -> stored (wire-order) RGB565, the formula
  /// documented for YUV_MBS in docs/protocol.md.
  static uint16_t yuvToStored(int y, int u, int v) {
    auto clip = [](int t) { return t < 0 ? 0 : (t > 255 ? 255 : t); };
    int c = y - 16, d = u - 128, e = v - 128;
    int r = clip((298 * c + 409 * e + 128) >> 8);
    int g = clip((298 * c - 100 * d - 208 * e + 128) >> 8);
    int b = clip((298 * c + 516 * d + 128) >> 8);
    uint16_t native = static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
    return static_cast<uint16_t>((native << 8) | (native >> 8));
  }

 protected:
  void span(int xa, int xb, int y, uint16_t c) {
    for (int x = xa; x <= xb; ++x) put(x, y, c);
  }
};

}  // namespace tangnanogpu
