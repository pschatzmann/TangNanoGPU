/**
 * @file material-design.ino
 * @brief TinyMaterialDesign widgets on HDMI: the widget tree draws straight
 * onto SurfaceTangNano, so the Tang Nano 20K renders every frame - the MCU
 * needs no framebuffer at all. Frames are double buffered (tear-free).
 *
 * Input: HDMI has no touch screen, so this sketch includes SerialTouch, a
 * TinyGPU TouchDriver fed from the Serial Monitor (115200 baud, newline):
 *   tap 80 200             tap at (x, y)
 *   drag 20 136 280 136    press at (x0, y0), move to (x1, y1), release
 * Coordinates are framebuffer pixels (320x240). Any other TinyGPU
 * TouchDriver whose coordinates map to 320x240 can be used instead.
 *
 * Needs the TinyMaterialDesign library: see docs/tinymaterialdesign.md.
 */
#include <SPI.h>
#include <TangNanoGPU.h>
#include <TinyMaterialDesign.h>

#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;
#else
const int kCsPin = 10, kBusyPin = 9;
#endif

/// TouchDriver that replays "tap x y" / "drag x0 y0 x1 y1" Serial commands.
class SerialTouch : public TouchDriver {
 public:
  bool begin() override { return true; }

  /// Call once per loop(): reads complete command lines from Serial.
  void poll() {
    while (Serial.available()) {
      char c = Serial.read();
      if (c == '\n' || c == '\r') {
        line_[len_] = 0;
        if (len_ > 0) parse(line_);
        len_ = 0;
      } else if (len_ < sizeof(line_) - 1) {
        line_[len_++] = c;
      }
    }
  }

  bool isTouched() override { return active_ && millis() < endMs_; }

  bool getPoint(Point& p) override {
    if (!isTouched()) return false;
    // linear move from start to end over the gesture's duration
    uint32_t t = millis() - startMs_, d = endMs_ - startMs_;
    p.x = x0_ + (int32_t)(x1_ - x0_) * (int32_t)t / (int32_t)d;
    p.y = y0_ + (int32_t)(y1_ - y0_) * (int32_t)t / (int32_t)d;
    p.pressure = 255;
    return true;
  }

 protected:
  char line_[48];
  size_t len_ = 0;
  bool active_ = false;
  int16_t x0_ = 0, y0_ = 0, x1_ = 0, y1_ = 0;
  uint32_t startMs_ = 0, endMs_ = 0;

  void parse(const char* s) {
    int a, b, c, d;
    if (sscanf(s, "tap %d %d", &a, &b) == 2) {
      start(a, b, a, b, 60);
    } else if (sscanf(s, "drag %d %d %d %d", &a, &b, &c, &d) == 4) {
      start(a, b, c, d, 600);
    } else {
      Serial.println("commands: 'tap x y' or 'drag x0 y0 x1 y1'");
    }
  }

  void start(int x0, int y0, int x1, int y1, uint32_t ms) {
    x0_ = x0; y0_ = y0; x1_ = x1; y1_ = y1;
    startMs_ = millis();
    endMs_ = startMs_ + ms;
    active_ = true;
  }
};

// --- GPU ---------------------------------------------------------------------
TransportSPI transport(SPI, kCsPin, kBusyPin);
TangNanoGPU gpu(transport);
SurfaceTangNano surface(gpu);

// --- UI ----------------------------------------------------------------------
Screen<RGB565> screen(defaultTheme<RGB565>());
SerialTouch touch;
GestureDetector gestures;

AppBar<RGB565> appBar(Bounds(0, 0, 320, 48), "TangNanoGPU");
Label<RGB565> status(Bounds(16, 54, 288, 20), "tap / drag via Serial");
Switch<RGB565> toggle(Bounds(16, 82, 48, 28));
Label<RGB565> toggleLabel(Bounds(72, 86, 110, 20), "Switch: off");
Checkbox<RGB565> check(Bounds(196, 84, 24, 24), false);
Label<RGB565> checkLabel(Bounds(226, 86, 90, 20), "Check");
Slider<RGB565> slider(Bounds(16, 122, 288, 28), 0.0f, 100.0f, 40.0f);
LinearProgressIndicator<RGB565> progress(Bounds(16, 160, 288, 8), 0.4f);
Button<RGB565> openButton(Bounds(16, 184, 150, 40), "Open dialog");
CircularProgressIndicator<RGB565> spinner(Bounds(262, 180, 44, 44), 0.0f, /*indeterminate=*/true);

Dialog<RGB565> dialog(Bounds(30, 50, 260, 140), "Hello HDMI",
                      "This dialog and its scrim are drawn by the FPGA.");
Button<RGB565> dialogOk(Bounds(0, 0, 80, 36), "OK");

void setup() {
  Serial.begin(115200);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found");
    while (true) delay(1000);
  }
  surface.begin();
  surface.setTarget(1);  // draw into the hidden buffer, swap() shows it

  toggle.onChange = [](bool on) { toggleLabel.setText(on ? "Switch: on" : "Switch: off"); };
  check.onChange = [](bool on) { status.setText(on ? "checkbox checked" : "checkbox cleared"); };
  slider.onChange = [](float v) { progress.setValue(v / 100.0f); };
  openButton.onClick = []() { screen.presentDialog(dialog); };
  dialogOk.bounds = dialog.actionRect(0, 1);
  dialogOk.onClick = []() { screen.dismissDialog(); };
  dialog.addAction(dialogOk);

  screen.addFixedWidget(appBar);
  screen.addWidget(status);
  screen.addWidget(toggle);
  screen.addWidget(toggleLabel);
  screen.addWidget(check);
  screen.addWidget(checkLabel);
  screen.addWidget(slider);
  screen.addWidget(progress);
  screen.addWidget(openButton);
  screen.addWidget(spinner);

  gestures.onGesture = [](GestureEvent& e) { screen.handleGesture(e); };
  gestures.isDraggable = [](int16_t x, int16_t y) { return screen.isDraggableAt(x, y); };
  touch.begin();
  Serial.println("try: tap 90 204   (opens the dialog)");
}

void loop() {
  touch.poll();
  gestures.update(touch);
  screen.update(millis());
  if (screen.isDirty()) {
    screen.draw(surface);  // rendered by the FPGA into the back buffer
    surface.swap();        // shown at the next frame
    gpu.flush();           // stay at most one frame ahead of the display
  }
}
