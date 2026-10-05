#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "TangNanoGPU/Protocol.h"
#include "TangNanoGPU/Transport.h"

namespace tangnanogpu {

/// Decoded STATUS response.
struct GPUStatus {
  uint16_t cmdFree = 0;     ///< free bytes in the command FIFO
  uint8_t flags = 0;        ///< gpuflag::k* bits
  uint16_t frameCount = 0;  ///< frames started since reset (wraps)
  uint16_t respUsed = 0;    ///< bytes waiting in the response FIFO
  bool busy() const { return flags & gpuflag::kBusy; }
  bool sdramReady() const { return flags & gpuflag::kSdramReady; }
  bool error() const { return flags & (gpuflag::kOverflow | gpuflag::kBadOpcode); }
};

/**
 * @brief Low-level command interface to a TangNanoGPU board.
 *
 * Every method maps to one protocol command (docs/protocol.md) and returns
 * as soon as the command is queued - the FPGA draws in the background
 * while HDMI output keeps running. Coordinates are framebuffer pixels
 * (320x240); colours are TinyGPU RGB565 stored values (RGB565::getValue()).
 *
 * Single pixels are batched: pixel() collects them into one PIXELS command
 * that is sent when the batch is full or any other command is issued.
 */
class TangNanoGPU {
 public:
  explicit TangNanoGPU(ITransport& transport, uint8_t address = 0)
      : io_(transport), addr_(address) {}

  /// Starts the transport, checks the board answers PING and waits (up to
  /// timeoutMs) until its SDRAM is initialised. Resets the drawing state.
  bool begin(uint32_t timeoutMs = 1000) {
    if (!io_.begin()) return false;
    uint32_t start = io_.millis();
    while (!ping()) {
      if (io_.millis() - start > timeoutMs) return false;
      io_.delayMicros(1000);
    }
    // a quad transport needs a quad-capable bitstream (see docs/protocol.md)
    if (io_.isQuad() && !(caps_ & cap::kQuad)) return false;
    reset();
    while (!status().sdramReady()) {
      if (io_.millis() - start > timeoutMs) return false;
      io_.delayMicros(1000);
    }
    return true;
  }

  void end() { io_.end(); }

  // ------------------------------------------------------------------
  // Immediate commands
  // ------------------------------------------------------------------

  /// PING: true if the board answered "TANG"; version() and capabilities()
  /// then describe the gateware.
  bool ping() {
    uint8_t cmd[2] = {addr_, op::kPing};
    uint8_t resp[6];
    io_.beginTransaction(true);
    io_.write(cmd, 2);
    io_.read(resp, 6);
    io_.endTransaction();
    version_ = resp[4];
    caps_ = resp[5];
    return memcmp(resp, "TANG", 4) == 0;
  }

  /// Gateware version (kGatewareVersion for the bitstream shipped with this
  /// library).
  uint8_t version() const { return version_; }
  /// Capability bits (cap::k*), e.g. cap::kQuad.
  uint8_t capabilities() const { return caps_; }
  /// True if the bitstream accepts quad-SPI write transactions.
  bool supportsQuad() const { return caps_ & cap::kQuad; }

  /// RESET: flushes both FIFOs and resets the drawing engine (target,
  /// clip and sticky error flags). The picture on screen is kept.
  void reset() {
    pixelCount_ = 0;
    runLen_ = 0;
    cacheValid_ = false;
    uint8_t cmd[2] = {addr_, op::kReset};
    io_.beginTransaction(false);
    io_.write(cmd, 2);
    io_.endTransaction();
    cmdFreeEstimate_ = kCmdFifoBytes;
    target_ = 0;
  }

  GPUStatus status() {
    uint8_t cmd[2] = {addr_, op::kStatus};
    uint8_t r[7];
    io_.beginTransaction(true);
    io_.write(cmd, 2);
    io_.read(r, 7);
    io_.endTransaction();
    GPUStatus s;
    s.cmdFree = static_cast<uint16_t>(r[0] | (r[1] << 8));
    s.flags = r[2];
    s.frameCount = static_cast<uint16_t>(r[3] | (r[4] << 8));
    s.respUsed = static_cast<uint16_t>(r[5] | (r[6] << 8));
    cmdFreeEstimate_ = s.cmdFree;
    return s;
  }

  /// Blocks until every queued command has been executed.
  bool flush(uint32_t timeoutMs = 2000) {
    flushPixels();
    uint32_t start = io_.millis();
    while (status().busy()) {
      if (io_.millis() - start > timeoutMs) return false;
      io_.delayMicros(100);
    }
    return true;
  }

  // ------------------------------------------------------------------
  // Display / state
  // ------------------------------------------------------------------

  /// Selects the framebuffer (0/1) that following drawing goes to.
  void setTarget(uint8_t buffer) {
    uint8_t b[3];
    CommandBuilder c(b, addr_);
    c.u8(op::kSetTarget).u8(buffer & 1);
    send(c);
    target_ = buffer & 1;
  }
  uint8_t target() const { return target_; }

  /// Shows framebuffer `buffer` from the next frame on (switches during
  /// vertical blanking, so never tears).
  void show(uint8_t buffer) {
    uint8_t b[3];
    CommandBuilder c(b, addr_);
    c.u8(op::kShow).u8(buffer & 1);
    send(c);
  }

  /// Queues a fence: commands after it run only once the next frame has
  /// started (use after show() before drawing into the old front buffer).
  void waitVSync() {
    uint8_t b[2];
    CommandBuilder c(b, addr_);
    c.u8(op::kWaitVSync);
    send(c);
  }

  /// Sets the clip rectangle (intersected with the screen by the FPGA).
  void setClip(int x, int y, int w, int h) {
    uint8_t b[10];
    CommandBuilder c(b, addr_);
    c.u8(op::kSetClip).i16(x).i16(y).u16(clampU16(w)).u16(clampU16(h));
    send(c);
  }
  void resetClip() { setClip(0, 0, kWidth, kHeight); }

  // ------------------------------------------------------------------
  // Drawing
  // ------------------------------------------------------------------

  void fillRect(int x, int y, int w, int h, uint16_t color) {
    if (w <= 0 || h <= 0) return;
    uint8_t b[12];
    CommandBuilder c(b, addr_);
    c.u8(op::kFillRect).i16(x).i16(y).u16(clampU16(w)).u16(clampU16(h)).color(color);
    send(c);
  }

  void line(int x0, int y0, int x1, int y1, uint16_t color) {
    uint8_t b[12];
    CommandBuilder c(b, addr_);
    c.u8(op::kLine).i16(x0).i16(y0).i16(x1).i16(y1).color(color);
    send(c);
  }

  /// Circle outline or filled disc (TinyGPU midpoint algorithm).
  void circle(int x, int y, int r, uint16_t color, bool filled) {
    if (r < 0) return;
    uint8_t b[11];
    CommandBuilder c(b, addr_);
    c.u8(op::kCircle).i16(x).i16(y).u16(clampU16(r)).color(color).u8(filled ? 1 : 0);
    send(c);
  }

  /// Single pixel. Pixels are batched (see class description), and runs of
  /// consecutive pixels along a row are sent as one WRITE_RECT instead, so
  /// row-by-row setPixel() loops cost 2 bytes per pixel instead of 6.
  void pixel(int x, int y, uint16_t color) {
    // keep the readPixel() row cache in step. Like TinyGPU's setPixel(),
    // pixels are only bounded by the screen, not by the clip rect.
    if (cacheValid_ && y == cacheY_ && x >= 0 && x < kWidth) cache_[x] = color;
    if (runLen_ > 0 && y == runY_ && x == runX_ + static_cast<int>(runLen_) && runLen_ < kWidth) {
      runBuf_[runLen_ * 2] = color & 0xff;
      runBuf_[runLen_ * 2 + 1] = color >> 8;
      ++runLen_;
      return;
    }
    endRun();
    runX_ = x;
    runY_ = y;
    runBuf_[0] = color & 0xff;
    runBuf_[1] = color >> 8;
    runLen_ = 1;
  }

  /// Sends pending pixel() data (batch and run) now.
  void flushPixels() {
    endRun();
    flushBatch();
  }

  /// Colour of one framebuffer pixel (current target), as a TinyGPU stored
  /// RGB565 value. Reads a whole row over SPI and keeps it cached until the
  /// next drawing command, so per-pixel read-modify-write loops (e.g. a
  /// dimming scrim) cost one readback per row, not per pixel.
  uint16_t readPixel(int x, int y) {
    if (x < 0 || x >= kWidth || y < 0 || y >= kHeight) return 0;
    if (!(cacheValid_ && cacheY_ == y)) {
      uint8_t row[kWidth * 2];
      if (!readRect(0, y, kWidth, 1, row)) return 0;
      for (int i = 0; i < kWidth; ++i) cache_[i] = static_cast<uint16_t>(row[i * 2] | (row[i * 2 + 1] << 8));
      cacheY_ = y;
      cacheValid_ = true;
    }
    return cache_[x];
  }

  /// Writes a w x h block of pixels at (x, y). `pixels` is in TinyGPU's
  /// RGB565 memory layout (Surface<RGB565>::data()), row-major, with
  /// `strideBytes` bytes between rows (0 = w*2). If useKey is set, pixels
  /// equal to `key` are left untouched (TinyGPU drawSprite semantics).
  void writeRect(int x, int y, int w, int h, const uint8_t* pixels,
                 size_t strideBytes = 0, bool useKey = false, uint16_t key = 0) {
    if (w <= 0 || h <= 0) return;
    if (strideBytes == 0) strideBytes = static_cast<size_t>(w) * 2;
    int band = rowsPerCommand(static_cast<size_t>(w) * 2, 11);
    for (int r = 0; r < h; r += band) {
      int n = (h - r < band) ? h - r : band;
      uint8_t b[14];
      CommandBuilder c(b, addr_);
      c.u8(op::kWriteRect).i16(x).i16(y + r).u16(w).u16(n).u8(useKey ? 1 : 0).color(key);
      sendRows(c, pixels + r * strideBytes, static_cast<size_t>(w) * 2, strideBytes, n);
    }
  }

  /// Stores a w x h image (w <= 512) in SDRAM image memory starting at
  /// SDRAM row `row` (>= kImageRowBase; the image uses h rows). Draw it
  /// with blit(). Pixel layout as for writeRect().
  void uploadImage(uint16_t row, int w, int h, const uint8_t* pixels, size_t strideBytes = 0) {
    if (w <= 0 || h <= 0 || w > kMaxImageWidth) return;
    if (strideBytes == 0) strideBytes = static_cast<size_t>(w) * 2;
    int band = rowsPerCommand(static_cast<size_t>(w) * 2, 8);
    for (int r = 0; r < h; r += band) {
      int n = (h - r < band) ? h - r : band;
      uint8_t b[9];
      CommandBuilder c(b, addr_);
      c.u8(op::kUpload).u16(row + r).u16(w).u16(n);
      sendRows(c, pixels + r * strideBytes, static_cast<size_t>(w) * 2, strideBytes, n);
    }
  }

  /// Copies a w x h block whose top-left pixel is (sx, sy) in the surface
  /// starting at SDRAM row `srcRow` to (dx, dy) in the current target,
  /// optionally skipping `key`-coloured pixels. srcRow = kImageRowBase+...
  /// blits an uploaded image; srcRow = kFrameBufferRow[b] copies from a
  /// framebuffer (overlapping copies inside one buffer are handled).
  void copyRect(uint16_t srcRow, int sx, int sy, int w, int h, int dx, int dy,
                bool useKey = false, uint16_t key = 0) {
    if (w <= 0 || h <= 0) return;
    uint8_t b[19];
    CommandBuilder c(b, addr_);
    c.u8(op::kCopyRect).u16(srcRow).u16(sx).u16(sy).u16(w).u16(h).i16(dx).i16(dy)
        .u8(useKey ? 1 : 0).color(key);
    send(c);
  }

  /// Draws an uploaded image (see uploadImage()).
  void blit(uint16_t row, int w, int h, int x, int y, bool useKey = false, uint16_t key = 0) {
    copyRect(row, 0, 0, w, h, x, y, useKey, key);
  }

  /// Writes 16x16 macroblocks of a YUV 4:2:0 (I420) picture; the FPGA
  /// converts them to RGB565 (BT.601 limited range, same integer formula
  /// as TinyH264's toRGB565()). The picture's top-left corner is placed at
  /// (x0, y0) in the framebuffer; `mbs` lists the macroblocks to send as
  /// row * mbCols + column. Macroblocks are clipped like writeRect().
  /// Y/U/V and the strides are the decoder's planes (U = Cb, V = Cr).
  void writeYuvMacroblocks(int x0, int y0, const uint8_t* Y, int strideY, const uint8_t* U,
                           const uint8_t* V, int strideUV, const uint16_t* mbs, size_t count,
                           int mbCols) {
    // without BUSY, keep each command inside half the FIFO
    size_t perCmd = io_.hasBusyPin() ? 0xffff : (kCmdFifoBytes / 2 - 4) / kMacroblockBytes;
    for (size_t first = 0; first < count; first += perCmd) {
      size_t n = (count - first < perCmd) ? count - first : perCmd;
      uint8_t hdr[4] = {addr_, op::kYuvMacroblocks, static_cast<uint8_t>(n & 0xff),
                        static_cast<uint8_t>(n >> 8)};
      flushPixels();
      cacheValid_ = false;
      reserve(4 + n * kMacroblockBytes);
      io_.beginTransaction(false);
      io_.write(hdr, 4);
      uint8_t mb[kMacroblockBytes];
      for (size_t k = first; k < first + n; ++k) {
        int col = mbs[k] % mbCols, row = mbs[k] / mbCols;
        uint16_t x = static_cast<uint16_t>(static_cast<int16_t>(x0 + col * 16));
        uint16_t y = static_cast<uint16_t>(static_cast<int16_t>(y0 + row * 16));
        mb[0] = x & 0xff; mb[1] = x >> 8; mb[2] = y & 0xff; mb[3] = y >> 8;
        const uint8_t* u = U + static_cast<size_t>(row) * 8 * strideUV + col * 8;
        const uint8_t* v = V + static_cast<size_t>(row) * 8 * strideUV + col * 8;
        for (int r = 0; r < 8; ++r) {
          memcpy(mb + 4 + r * 8, u + static_cast<size_t>(r) * strideUV, 8);
          memcpy(mb + 68 + r * 8, v + static_cast<size_t>(r) * strideUV, 8);
        }
        const uint8_t* yy = Y + static_cast<size_t>(row) * 16 * strideY + col * 16;
        for (int r = 0; r < 16; ++r) memcpy(mb + 132 + r * 16, yy + static_cast<size_t>(r) * strideY, 16);
        io_.write(mb, kMacroblockBytes);
      }
      io_.endTransaction();
    }
  }

  /// Draws a 1bpp (fg where set) or 2bpp (01 = fg, 10 = bg, else skip)
  /// bitmap, MSB first, each row padded to a whole byte.
  void mask(int x, int y, int w, int h, bool twoBpp, uint16_t fg, uint16_t bg,
            const uint8_t* bits) {
    if (w <= 0 || h <= 0) return;
    size_t rowBytes = (static_cast<size_t>(w) * (twoBpp ? 2 : 1) + 7) / 8;
    int band = rowsPerCommand(rowBytes, 13);
    for (int r = 0; r < h; r += band) {
      int n = (h - r < band) ? h - r : band;
      uint8_t b[15];
      CommandBuilder c(b, addr_);
      c.u8(op::kMask).i16(x).i16(y + r).u16(w).u16(n).u8(twoBpp ? 1 : 0).color(fg).color(bg);
      sendRows(c, bits + r * rowBytes, rowBytes, rowBytes, n);
    }
  }

  /// Reads back a w x h block of the current target into `out` (TinyGPU
  /// RGB565 memory layout, w*h*2 bytes). The block must lie inside the
  /// framebuffer. Waits for all queued drawing first.
  bool readRect(int x, int y, int w, int h, uint8_t* out, uint32_t timeoutMs = 1000) {
    if (w <= 0 || h <= 0) return true;
    // one READ_RECT per band that fits the response FIFO
    int rowsMax = static_cast<int>(kRespFifoBytes / (static_cast<size_t>(w) * 2));
    if (rowsMax < 1) return false;  // w > 1023: cannot happen for a 320-wide screen
    for (int r = 0; r < h; r += rowsMax) {
      int n = (h - r < rowsMax) ? h - r : rowsMax;
      uint8_t b[10];
      CommandBuilder c(b, addr_);
      c.u8(op::kReadRect).u16(x).u16(y + r).u16(w).u16(n);
      send(c);
      size_t need = static_cast<size_t>(w) * n * 2;
      uint32_t start = io_.millis();
      while (status().respUsed < need) {
        if (io_.millis() - start > timeoutMs) return false;
        io_.delayMicros(50);
      }
      uint8_t cmd[2] = {addr_, op::kReadData};
      io_.beginTransaction(true);
      io_.write(cmd, 2);
      io_.read(out + static_cast<size_t>(r) * w * 2, need);
      io_.endTransaction();
    }
    return true;
  }

  ITransport& transport() { return io_; }

 protected:
  static constexpr size_t kPixelBatch = 64;
  ITransport& io_;
  uint8_t addr_;
  uint8_t version_ = 0;
  uint8_t caps_ = 0;
  uint8_t target_ = 0;
  size_t cmdFreeEstimate_ = kCmdFifoBytes;
  size_t pixelCount_ = 0;
  uint8_t pixelBuf_[4 + kPixelBatch * 6];  // [addr][op][n lo][n hi] + 6 bytes/pixel
  // run of consecutive pixels on one row (sent as WRITE_RECT if long enough)
  static constexpr size_t kMinRun = 4;
  int runX_ = 0, runY_ = 0;
  size_t runLen_ = 0;
  uint8_t runBuf_[kWidth * 2];
  // readPixel() row cache
  bool cacheValid_ = false;
  int cacheY_ = 0;
  uint16_t cache_[kWidth];

  void addToBatch(int x, int y, uint16_t color) {
    uint8_t* p = pixelBuf_ + 4 + pixelCount_ * 6;
    uint16_t ux = static_cast<uint16_t>(static_cast<int16_t>(x));
    uint16_t uy = static_cast<uint16_t>(static_cast<int16_t>(y));
    p[0] = ux & 0xff; p[1] = ux >> 8;
    p[2] = uy & 0xff; p[3] = uy >> 8;
    p[4] = color & 0xff; p[5] = color >> 8;
    if (++pixelCount_ == kPixelBatch) flushBatch();
  }

  void flushBatch() {
    if (pixelCount_ == 0) return;
    size_t n = pixelCount_;
    pixelCount_ = 0;
    pixelBuf_[0] = addr_;
    pixelBuf_[1] = op::kPixels;
    pixelBuf_[2] = n & 0xff;
    pixelBuf_[3] = n >> 8;
    sendRaw(pixelBuf_, 4 + n * 6);
  }

  /// Ends the current run: short runs join the PIXELS batch, long ones go
  /// out as one WRITE_RECT row (after the older batched pixels).
  void endRun() {
    if (runLen_ == 0) return;
    size_t n = runLen_;
    runLen_ = 0;
    if (n < kMinRun) {
      for (size_t i = 0; i < n; ++i)
        addToBatch(runX_ + static_cast<int>(i), runY_,
                   static_cast<uint16_t>(runBuf_[i * 2] | (runBuf_[i * 2 + 1] << 8)));
      return;
    }
    flushBatch();
    uint8_t b[14];
    CommandBuilder c(b, addr_);
    // flags bit 1: ignore the clip rect (setPixel() semantics)
    c.u8(op::kWriteRect).i16(runX_).i16(runY_).u16(static_cast<uint16_t>(n)).u16(1).u8(2).color(0);
    reserve(c.size() + n * 2);
    io_.beginTransaction(false);
    io_.write(c.data(), c.size());
    io_.write(runBuf_, n * 2);
    io_.endTransaction();
  }

  static uint16_t clampU16(int v) {
    return static_cast<uint16_t>(v < 0 ? 0 : (v > 0xffff ? 0xffff : v));
  }

  /// Rows per command so that one command never needs more FIFO space than
  /// is safe without a BUSY pin.
  int rowsPerCommand(size_t rowBytes, size_t headerBytes) const {
    if (io_.hasBusyPin()) return 0x7fff;
    size_t budget = kCmdFifoBytes / 2;
    if (rowBytes + headerBytes >= budget) return 1;
    return static_cast<int>((budget - headerBytes) / rowBytes);
  }

  /// Without a BUSY pin: make sure `len` bytes fit into the command FIFO.
  void reserve(size_t len) {
    if (io_.hasBusyPin()) return;
    uint32_t start = io_.millis();
    while (cmdFreeEstimate_ < len) {
      status();  // refreshes cmdFreeEstimate_
      if (cmdFreeEstimate_ >= len || io_.millis() - start > 2000) break;
      io_.delayMicros(50);
    }
    cmdFreeEstimate_ = cmdFreeEstimate_ > len ? cmdFreeEstimate_ - len : 0;
  }

  void send(const CommandBuilder& c) {
    flushPixels();
    cacheValid_ = false;
    sendRaw(c.data(), c.size());
  }

  void sendRaw(const uint8_t* data, size_t len) {
    reserve(len);
    io_.beginTransaction(false);
    io_.write(data, len);
    io_.endTransaction();
  }

  void sendRows(const CommandBuilder& c, const uint8_t* rows, size_t rowBytes,
                size_t stride, int n) {
    flushPixels();
    cacheValid_ = false;
    reserve(c.size() + rowBytes * n);
    io_.beginTransaction(false);
    io_.write(c.data(), c.size());
    if (stride == rowBytes) {
      io_.write(rows, rowBytes * n);
    } else {
      for (int i = 0; i < n; ++i) io_.write(rows + i * stride, rowBytes);
    }
    io_.endTransaction();
  }
};

}  // namespace tangnanogpu
