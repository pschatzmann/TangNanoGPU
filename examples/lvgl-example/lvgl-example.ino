/**
 * @file lvgl-example.ino
 * @brief LVGL on HDMI: TinyGPU's LVGLDriver renders LVGL's partial updates
 * into small buffers on the MCU and hands them to DisplayDriverTangNano,
 * which writes them into the Tang Nano 20K framebuffer.
 *
 * Needs the lvgl library (v9) and an lv_conf.h with LV_COLOR_DEPTH 16.
 */
#include <SPI.h>
#include <TangNanoGPU.h>
#include <TinyGPU/Integrations/LVGLDriver.h>
#include <lvgl.h>

#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;
#else
const int kCsPin = 10, kBusyPin = 9;
#endif

TransportSPI transport(SPI, kCsPin, kBusyPin);
TangNanoGPU gpu(transport);
DisplayDriverTangNano display(gpu);
LVGLDriver<RGB565> lvglDriver(display, kWidth, kHeight, kWidth * 20 * 2);

lv_obj_t* label = nullptr;
lv_obj_t* arc = nullptr;

void tick(lv_timer_t*) {
  static int value = 0;
  value = (value + 1) % 101;
  lv_arc_set_value(arc, value);
  lv_label_set_text_fmt(label, "%d %%", value);
}

void setup() {
  Serial.begin(115200);
  if (!lvglDriver.begin()) {  // also starts the TangNanoGPU link
    Serial.println("LVGL / Tang Nano 20K initialisation failed");
    while (true) delay(1000);
  }

  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_hex(0x101418), LV_PART_MAIN);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "LVGL on HDMI");
  lv_obj_set_style_text_color(title, lv_color_white(), LV_PART_MAIN);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 8);

  arc = lv_arc_create(scr);
  lv_obj_set_size(arc, 150, 150);
  lv_obj_center(arc);
  lv_arc_set_range(arc, 0, 100);

  label = lv_label_create(scr);
  lv_obj_set_style_text_color(label, lv_color_white(), LV_PART_MAIN);
  lv_obj_center(label);

  lv_timer_create(tick, 50, nullptr);
}

void loop() {
  lv_timer_handler();
  lvglDriver.delay(5);
}
