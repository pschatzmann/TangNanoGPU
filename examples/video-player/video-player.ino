/**
 * @file video-player.ino
 * @brief H.264 video on HDMI: TinyH264 decodes on the MCU, YUVFrameWriter
 * sends only the macroblocks that changed (as YUV 4:2:0, 1.5 bytes per
 * pixel) and the Tang Nano 20K converts them to RGB565. Double buffered,
 * so frames switch tear-free.
 *
 * The clip (clip.h) is 256x192, centred on the 320x240 screen. That size
 * keeps TinyH264's frame buffers small enough for an ESP32 without PSRAM;
 * full 320x240 decoding needs more RAM (e.g. an ESP32-S3 with PSRAM).
 *
 * Needs the TinyH264 library (GPL-3.0): see docs/video.md.
 */
#include <SPI.h>
#include <TangNanoGPU.h>
#include <TinyH264Decoder.h>

#include "clip.h"

// Interface: plain SPI (any MCU) or quad SPI (ESP32 family, IO2/IO3 wired
// to FPGA pins 25/26) - uncomment to select quad:
// #define TANGNANOGPU_LINK_QSPI

#if defined(TANGNANOGPU_LINK_QSPI) && defined(ESP32)
#if CONFIG_IDF_TARGET_ESP32
// VSPI IO_MUX pins: SCK 18, IO0/MOSI 23, IO1/MISO 19, IO2 22, IO3 21, CS 5, BUSY 4
TransportQSPI_ESP32 transport(18, 23, 19, 22, 21, 5, 4);
#else
// SCK 12, IO0 11, IO1 13, IO2 14, IO3 9, CS 10, BUSY 8
TransportQSPI_ESP32 transport(12, 11, 13, 14, 9, 10, 8);
#endif
#else
#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;     // VSPI: SCK 18, MISO 19, MOSI 23
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;   // SPI0: SCK 18, MOSI 19, MISO 16
#else
const int kCsPin = 10, kBusyPin = 9;
#endif
TransportSPI transport(SPI, kCsPin, kBusyPin);
#endif
TangNanoGPU gpu(transport);
SurfaceTangNano screen(gpu);
YUVFrameWriter video(gpu);
tinyh264::TinyH264Decoder<> decoder;

static uint8_t clipBuf[kClipSize];
bool realtime = true;  // false: as fast as possible (benchmark)
uint32_t nextFrameMs = 0;
uint32_t frames = 0, macroblocks = 0, statsStart = 0;

void onFrame(tinyh264::TinyH264Decoder<>& d, void*) {
  if (video.macroblocks() == 0) video.begin(d.width(), d.height());  // centred

  // send the changed macroblocks into the hidden buffer, then show it
  macroblocks += video.writeFrame(d.y(), d.strideY(), d.u(), d.v(), d.strideUV());
  screen.swap();
  gpu.flush();  // stay at most one frame ahead of the display

  if (realtime) {
    while ((int32_t)(millis() - nextFrameMs) < 0) {
    }
    nextFrameMs += 1000 / kClipFps;
  }

  if (++frames == 30) {
    uint32_t ms = millis() - statsStart;
    Serial.printf("%.1f fps, %u of %u macroblocks per frame sent\n", frames * 1000.0f / ms,
                  (unsigned)(macroblocks / frames), (unsigned)video.macroblocks());
    frames = macroblocks = 0;
    statsStart = millis();
  }
}

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  screen.begin();
  // black borders around the 256x192 picture, in both buffers
  screen.setTarget(0);
  screen.clear(RGB565(0, 0, 0));
  screen.setTarget(1);
  screen.clear(RGB565(0, 0, 0));

  decoder.setMaxDimension(256, 192);
  decoder.setMaxRefFrames(1);
  decoder.setCallback(onFrame);
  memcpy_P(clipBuf, kClip, kClipSize);
  nextFrameMs = statsStart = millis();
}

void loop() {
  // the clip starts with an IDR frame, so replaying it loops cleanly
  decoder.write(clipBuf, kClipSize);
  if (decoder.hasError()) {
    Serial.println("decoder error");
    while (true) delay(1000);
  }
}
