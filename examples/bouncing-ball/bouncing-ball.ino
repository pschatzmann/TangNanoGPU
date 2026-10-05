/**
 * @file bouncing-ball.ino
 * @brief Tear-free animation with double buffering: each frame is drawn
 * into the hidden framebuffer, then swap() shows it at the next vertical
 * blank. The MCU only sends a handful of short commands per frame.
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

const int kRadius = 14;
float x = 60, y = 50, vx = 2.3f, vy = 1.7f;
uint32_t frames = 0, lastReport = 0;

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  screen.begin();
  screen.setTarget(1);  // draw into buffer 1 while buffer 0 is shown
}

void loop() {
  x += vx;
  y += vy;
  if (x < kRadius || x > kWidth - kRadius) vx = -vx;
  if (y < kRadius || y > kHeight - kRadius) vy = -vy;

  screen.clear(RGB565(0, 0, 40));
  screen.drawRect(0, 0, kWidth, kHeight, RGB565(80, 80, 160));
  screen.fillCircle(x, y, kRadius, RGB565(255, 200, 0));
  screen.drawCircle(x, y, kRadius, RGB565(255, 255, 255));
  screen.drawText(6, 6, "double buffered", RGB565(200, 200, 255));
  screen.swap();  // show this frame, continue in the other buffer

  // keep the MCU at most one frame ahead of the display
  gpu.flush();

  ++frames;
  if (millis() - lastReport > 2000) {
    Serial.printf("%.1f fps\n", frames * 1000.0f / (millis() - lastReport));
    frames = 0;
    lastReport = millis();
  }
}
