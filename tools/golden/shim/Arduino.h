#pragma once
// Minimal Arduino stand-in for this desktop-only test tool: just what the
// TinyGPU / TinyMaterialDesign headers it compiles refer to (millis(),
// delay(), Serial.print*). Not a general Arduino emulation.
#include <stdint.h>
#include <stdio.h>

#include <chrono>
#include <thread>

inline uint32_t millis() {
  using namespace std::chrono;
  static const auto start = steady_clock::now();
  return static_cast<uint32_t>(duration_cast<milliseconds>(steady_clock::now() - start).count());
}
inline void delay(uint32_t ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

struct ShimSerial {
  void begin(unsigned long) {}
  template <typename T> void print(const T&) {}
  template <typename T> void println(const T&) {}
  void println() {}
  template <typename... A> void printf(const char*, A...) {}
};
inline ShimSerial Serial;
