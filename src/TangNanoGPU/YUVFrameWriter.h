#pragma once
#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "TangNanoGPU/GPUDevice.h"

namespace tangnanogpu {

/**
 * @brief Shows decoded video frames (YUV 4:2:0 / I420, e.g. from TinyH264)
 * on the Tang Nano 20K, sending only the 16x16 macroblocks that changed.
 *
 * The FPGA converts YUV to RGB565 itself, so a macroblock costs 1.5 bytes
 * per pixel on SPI instead of 2. On top of that, every macroblock is
 * hashed and compared with what the target framebuffer already holds;
 * unchanged macroblocks (static backgrounds, most of a typical P-frame)
 * are not sent at all.
 *
 * Why hashes and not the decoder's "skip" flags: an H.264 P_Skip
 * macroblock is still motion-compensated with a predicted vector and can
 * be altered by the deblocking filter, so "skipped" does not mean
 * "unchanged". Comparing content is always correct and works with any
 * decoder. Hashes are kept per framebuffer, so double buffering works:
 * each buffer is compared with what it holds itself.
 *
 * Memory: 2 x 4 bytes per macroblock (QVGA: 300 macroblocks = 2.4 KB) plus
 * a 2-byte index per macroblock.
 *
 * Usage with TinyH264:
 *
 *   YUVFrameWriter video(gpu);
 *   video.begin(decoder.width(), decoder.height());   // centred
 *   // in the decoder's frame callback:
 *   video.writeFrame(d.y(), d.strideY(), d.u(), d.v(), d.strideUV());
 */
class YUVFrameWriter {
 public:
  explicit YUVFrameWriter(TangNanoGPU& gpu) : gpu_(gpu) {}

  /// Sets the picture size (multiples of 16, as decoded H.264 pictures are)
  /// and its top-left position in the 320x240 framebuffer. By default the
  /// picture is centred; larger pictures are cropped by the screen edges.
  bool begin(int width, int height, int x = kCentre, int y = kCentre) {
    if (width <= 0 || height <= 0 || (width % 16) || (height % 16)) return false;
    mbCols_ = width / 16;
    mbRows_ = height / 16;
    x0_ = (x == kCentre) ? (kWidth - width) / 2 : x;
    y0_ = (y == kCentre) ? (kHeight - height) / 2 : y;
    size_t n = static_cast<size_t>(mbCols_) * mbRows_;
    for (int b = 0; b < 2; ++b) hashes_[b].assign(n, 0);
    list_.assign(n, 0);
    invalidate();
    return true;
  }

  /// Forces the next writeFrame() into each buffer to send every
  /// macroblock - call it after drawing over the video area.
  void invalidate() {
    valid_[0] = valid_[1] = false;
  }

  /// When false, every visible macroblock is sent on every frame.
  void setChangeDetection(bool on) { detect_ = on; }

  /// Sends the macroblocks of this frame that differ from what the current
  /// target buffer shows. Returns the number of macroblocks sent.
  size_t writeFrame(const uint8_t* Y, int strideY, const uint8_t* U, const uint8_t* V,
                    int strideUV) {
    const int b = gpu_.target();
    size_t count = 0;
    for (int row = 0; row < mbRows_; ++row) {
      int py = y0_ + row * 16;
      if (py <= -16 || py >= kHeight) continue;  // completely off-screen
      for (int col = 0; col < mbCols_; ++col) {
        int px = x0_ + col * 16;
        if (px <= -16 || px >= kWidth) continue;
        size_t i = static_cast<size_t>(row) * mbCols_ + col;
        uint32_t h = hashMacroblock(Y, strideY, U, V, strideUV, row, col);
        if (detect_ && valid_[b] && hashes_[b][i] == h) continue;
        hashes_[b][i] = h;
        list_[count++] = static_cast<uint16_t>(i);
      }
    }
    valid_[b] = true;
    if (count > 0)
      gpu_.writeYuvMacroblocks(x0_, y0_, Y, strideY, U, V, strideUV, list_.data(), count, mbCols_);
    lastCount_ = count;
    return count;
  }

  /// Macroblocks sent by the last writeFrame().
  size_t lastCount() const { return lastCount_; }
  /// Macroblocks per frame.
  size_t macroblocks() const { return static_cast<size_t>(mbCols_) * mbRows_; }
  int x() const { return x0_; }
  int y() const { return y0_; }

 protected:
  static constexpr int kCentre = -32768;
  TangNanoGPU& gpu_;
  int mbCols_ = 0, mbRows_ = 0, x0_ = 0, y0_ = 0;
  std::vector<uint32_t> hashes_[2];
  bool valid_[2] = {false, false};
  bool detect_ = true;
  std::vector<uint16_t> list_;
  size_t lastCount_ = 0;

  /// FNV-1a over the macroblock's 16x16 luma and 8x8 + 8x8 chroma.
  static uint32_t hashMacroblock(const uint8_t* Y, int strideY, const uint8_t* U,
                                 const uint8_t* V, int strideUV, int row, int col) {
    uint32_t h = 2166136261u;
    const uint8_t* y = Y + static_cast<size_t>(row) * 16 * strideY + col * 16;
    for (int r = 0; r < 16; ++r, y += strideY)
      for (int i = 0; i < 16; ++i) h = (h ^ y[i]) * 16777619u;
    const uint8_t* u = U + static_cast<size_t>(row) * 8 * strideUV + col * 8;
    const uint8_t* v = V + static_cast<size_t>(row) * 8 * strideUV + col * 8;
    for (int r = 0; r < 8; ++r, u += strideUV, v += strideUV)
      for (int i = 0; i < 8; ++i) h = (((h ^ u[i]) * 16777619u) ^ v[i]) * 16777619u;
    return h;
  }
};

}  // namespace tangnanogpu
