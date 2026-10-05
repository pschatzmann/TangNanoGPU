#pragma once
#include "TinyGPU.h"
#include "TinyGPU/Drivers/DisplayDriver.h"
#include "TangNanoGPU/SurfaceTangNano.h"

namespace tangnanogpu {

/**
 * @brief TinyGPU DisplayDriver that writes rendered surfaces into the
 * Tang Nano 20K framebuffer (shown on HDMI at 640x480, pixel-doubled).
 *
 * Use it wherever TinyGPU expects a DisplayDriver<RGB565>: DeviceOutput,
 * LVGLDriver (partial flushes via writeData(surface, x, y)), or your own
 * code that renders into an in-memory Surface<RGB565> first.
 */
class DisplayDriverTangNano : public tinygpu::DisplayDriver<RGB565> {
 public:
  explicit DisplayDriverTangNano(TangNanoGPU& gpu) : gpu_(gpu), surface_(gpu) {}

  bool begin() override { return gpu_.begin() && surface_.begin(); }
  void end() override { gpu_.flushPixels(); }

  bool writeData(ISurface<RGB565>& surface) override { return writeData(surface, 0, 0); }

  bool writeData(ISurface<RGB565>& surface, size_t x, size_t y) override {
    surface_.writeSurface(static_cast<int>(x), static_cast<int>(y), surface);
    return true;
  }

  size_t width() const override { return kWidth; }
  size_t height() const override { return kHeight; }

  TangNanoGPU& gpu() { return gpu_; }

 protected:
  TangNanoGPU& gpu_;
  SurfaceTangNano surface_;

  bool setAddressWindow(size_t, size_t, size_t, size_t) override { return true; }
};

}  // namespace tangnanogpu
