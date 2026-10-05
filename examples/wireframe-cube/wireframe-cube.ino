/**
 * @file wireframe-cube.ino
 * @brief TinyGPU's WireFrame3D rotating cube, drawn by the FPGA: the
 * projection runs on the MCU, the pixels are batched into PIXELS commands
 * and rendered into the Tang Nano 20K's back buffer.
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
WireFrame3D_RGB565 wireframe(screen);
auto cubeMesh = WireFrame3D_RGB565::cube(2.0f);
float angle = 0.0f;

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  screen.begin();
  screen.setTarget(1);

  wireframe.begin();
  wireframe.setPerspective(60.0f, 0.1f, 100.0f);
  WireFrame3D_RGB565::Camera cam;
  cam.position = {0.0f, 0.0f, 5.0f};
  cam.target = {0.0f, 0.0f, 0.0f};
  cam.up = {0.0f, 1.0f, 0.0f};
  wireframe.setCamera(cam);
}

void loop() {
  screen.clear(RGB565(255, 255, 255));
  screen.drawText(4, 4, "Rotating Wireframe Cube Demo", RGB565(0, 0, 255));

  auto model = WireFrame3D_RGB565::rotationY(angle) * WireFrame3D_RGB565::rotationX(angle * 0.7f);
  wireframe.renderWireframe(screen, cubeMesh, model, RGB565(0, 0, 0));

  screen.swap();
  gpu.flush();
  angle += 0.03f;
}
