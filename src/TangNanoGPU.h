#pragma once
/**
 * TangNanoGPU: a TinyGPU drawing engine with HDMI output on a Sipeed
 * Tang Nano 20K FPGA, driven over SPI by a microcontroller.
 *
 *   TransportSPI          - SPI + chip select + BUSY pin (Arduino)
 *   TangNanoGPU           - protocol commands (fill, line, circle, blit ...)
 *   SurfaceTangNano       - TinyGPU ISurface<RGB565> drawn by the FPGA
 *   DisplayDriverTangNano - TinyGPU DisplayDriver<RGB565> (HDMI "panel")
 *   YUVFrameWriter        - decoded video (I420) as changed macroblocks
 *
 * See README.md and docs/ for wiring, protocol and gateware.
 */
#if defined(ARDUINO)
// TinyGPU's touch drivers use TwoWire, but TinyGPU/Emulation.h only pulls
// in <Wire.h> via __has_include - which arduino-cli's library discovery
// doesn't see. Including it here makes the build find the Wire library.
#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>
#endif
#include "TinyGPU.h"
#include "TangNanoGPU/Protocol.h"
#include "TangNanoGPU/Transport.h"
#include "TangNanoGPU/GPUDevice.h"
#include "TangNanoGPU/SurfaceTangNano.h"
#include "TangNanoGPU/DisplayDriverTangNano.h"
#include "TangNanoGPU/YUVFrameWriter.h"
#if defined(ARDUINO)
#include "TangNanoGPU/TransportSPI.h"
#endif

#if defined(ARDUINO) || defined(TANGNANOGPU_AUTO_NAMESPACE)
using namespace tangnanogpu;
#endif
