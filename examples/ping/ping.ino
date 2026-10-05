/**
 * @file ping.ino
 * @brief Checks the wiring to a Tang Nano 20K running the TangNanoGPU
 * bitstream: PING, STATUS, and a colour cycle on the HDMI output.
 *
 * Wiring (Tang Nano 20K pin -> MCU): 73 SCK, 74 MOSI, 75 MISO, 76 CS,
 * 71 BUSY, GND - GND. All 3.3V. See docs/pinout.md.
 */
#include <SPI.h>
#include <TangNanoGPU.h>

#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;     // VSPI: SCK 18, MISO 19, MOSI 23
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;   // SPI0: SCK 18, MOSI 19, MISO 16
#else
const int kCsPin = 10, kBusyPin = 9;
#endif

TransportSPI transport(SPI, kCsPin, kBusyPin);
TangNanoGPU gpu(transport);

void setup() {
  Serial.begin(115200);
  delay(1000);
  if (!gpu.begin()) {
    Serial.println("No answer from the Tang Nano 20K - check wiring and bitstream");
    while (true) delay(1000);
  }
  Serial.print("TangNanoGPU gateware version ");
  Serial.println(gpu.version());
}

void loop() {
  static uint8_t hue = 0;
  // simple colour wheel on the whole screen
  uint8_t r = hue < 85 ? 255 - hue * 3 : hue < 170 ? 0 : (hue - 170) * 3;
  uint8_t g = hue < 85 ? hue * 3 : hue < 170 ? 255 - (hue - 85) * 3 : 0;
  uint8_t b = hue < 85 ? 0 : hue < 170 ? (hue - 85) * 3 : 255 - (hue - 170) * 3;
  gpu.fillRect(0, 0, kWidth, kHeight, RGB565(r, g, b).getValue());
  hue += 4;

  GPUStatus s = gpu.status();
  Serial.printf("frames=%u cmdFree=%u flags=0x%02x%s\n", s.frameCount, s.cmdFree, s.flags,
                s.error() ? " ERROR" : "");
  delay(500);
}
