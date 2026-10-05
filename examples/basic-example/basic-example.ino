/**
 * @file basic-example.ino
 * @brief TinyGPU drawing primitives rendered by the FPGA: SurfaceTangNano
 * is a TinyGPU ISurface<RGB565>, so the usual drawing calls work unchanged
 * while the Tang Nano 20K draws them into its framebuffer and shows the
 * result on HDMI (320x240, pixel-doubled to 640x480).
 */
#include <SPI.h>
#include <TangNanoGPU.h>

#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;
#else
const int kCsPin = 10, kBusyPin = 9;
#endif

TransportSPI transport(SPI, kCsPin, kBusyPin);
TangNanoGPU gpu(transport);
SurfaceTangNano screen(gpu);

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  screen.begin();
  screen.clear(RGB565(16, 16, 48));

  screen.fillRect(10, 10, 100, 60, RGB565(255, 0, 0));
  screen.drawRect(120, 10, 100, 60, RGB565(255, 255, 0));
  screen.fillRoundRect(230, 10, 80, 60, 12, RGB565(0, 160, 255));

  for (int i = 0; i < 16; ++i)
    screen.drawLine(160, 150, 160 + 70 * cos(i * PI / 8), 150 + 70 * sin(i * PI / 8),
                    RGB565(255, i * 16, 255 - i * 16));

  screen.drawCircle(60, 160, 40, RGB565(0, 255, 0));
  screen.fillCircle(270, 160, 35, RGB565(255, 0, 255));
  screen.drawArc(160, 150, 80, 200, 340, RGB565(255, 255, 255), 3);

  screen.drawText(10, 220, "Hello from the Tang Nano 20K!", RGB565(255, 255, 255));
  screen.drawText(10, 80, "TinyGPU", RGB565(255, 255, 0), RGB565(0, 0, 128), true, 2);

  gpu.flush();  // wait until everything is drawn
  Serial.println("done");
}

void loop() {}
