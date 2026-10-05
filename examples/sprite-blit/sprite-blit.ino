/**
 * @file sprite-blit.ino
 * @brief Sprites stored in the FPGA's SDRAM: a sprite is uploaded once with
 * uploadImage(); after that every frame only sends tiny BLIT commands, and
 * the FPGA copies the pixels (with colour-key transparency) itself.
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

const int kSize = 24;
const uint16_t kSpriteRow = kImageRowBase;  // SDRAM row where the sprite is kept
const int kCount = 40;
struct Ball {
  float x, y, vx, vy;
} balls[kCount];

void makeSprite() {
  SpriteRGB565 sprite(kSize, kSize, FontRGB565);
  sprite.begin();
  sprite.clear(RGB565());  // 0 = transparent (colour key)
  sprite.fillCircle(kSize / 2, kSize / 2, kSize / 2 - 1, RGB565(0, 120, 255));
  sprite.fillCircle(kSize / 2 - 3, kSize / 2 - 3, 4, RGB565(220, 240, 255));
  gpu.uploadImage(kSpriteRow, kSize, kSize, sprite.data());
}

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  screen.begin();
  makeSprite();
  for (auto& b : balls) {
    b = {float(random(kWidth - kSize)), float(random(kHeight - kSize)),
         random(-30, 30) / 10.0f, random(-30, 30) / 10.0f};
  }
  screen.setTarget(1);
}

void loop() {
  screen.clear(RGB565(20, 40, 20));
  for (auto& b : balls) {
    b.x += b.vx;
    b.y += b.vy;
    if (b.x < 0 || b.x > kWidth - kSize) b.vx = -b.vx;
    if (b.y < 0 || b.y > kHeight - kSize) b.vy = -b.vy;
    gpu.blit(kSpriteRow, kSize, kSize, b.x, b.y, true, 0);
  }
  screen.swap();
  gpu.flush();
}
