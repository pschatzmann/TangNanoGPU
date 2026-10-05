#pragma once
// Minimal stand-in for Arduino's Print, so TinyGPU.h (whose BMP/AVI
// writers include "Print.h") compiles in this desktop-only tool without
// the Arduino emulator. Only the write() overloads TinyGPU calls exist.
#include <stddef.h>
#include <stdint.h>

class Print {
 public:
  virtual ~Print() = default;
  virtual size_t write(uint8_t b) = 0;
  virtual size_t write(const uint8_t* data, size_t len) {
    size_t n = 0;
    while (len--) n += write(*data++);
    return n;
  }
};
