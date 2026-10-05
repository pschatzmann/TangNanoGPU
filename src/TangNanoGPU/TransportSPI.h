#pragma once
#include <Arduino.h>
#include <SPI.h>

#include "TangNanoGPU/Transport.h"

namespace tangnanogpu {

/**
 * @brief SPI transport (Arduino SPIClass) with chip select and an optional
 * BUSY input.
 *
 * Wiring (see docs/pinout.md): SCK -> FPGA pin 73, MOSI -> 74,
 * MISO <- 75, CS -> 76, BUSY <- 71 (all 3.3V).
 *
 * Writes run at `writeHz` (default 10MHz, max ~16MHz: the FPGA oversamples SCK with its
 * 64.8MHz system clock); transactions that read MISO run at `readHz`
 * (default 4MHz), because MISO is updated a few system clocks after SCK
 * falls.
 *
 * With a BUSY pin, write() sends in chunks of kChunk bytes and waits while
 * BUSY is high before each chunk, so one transaction can carry a payload of
 * any size. Without it (busyPin < 0), TangNanoGPU instead limits command
 * sizes and polls STATUS for free FIFO space.
 */
class TransportSPI : public ITransport {
 public:
  static constexpr size_t kChunk = 256;

  TransportSPI(SPIClass& spi, int csPin, int busyPin = -1,
               uint32_t writeHz = 10000000, uint32_t readHz = 4000000)
      : spi_(spi), cs_(csPin), busy_(busyPin), writeHz_(writeHz), readHz_(readHz) {}

  bool begin() override {
    pinMode(cs_, OUTPUT);
    digitalWrite(cs_, HIGH);
    if (busy_ >= 0) pinMode(busy_, INPUT);
    spi_.begin();
    return true;
  }

  void end() override { spi_.end(); }

  void beginTransaction(bool read) override {
    spi_.beginTransaction(SPISettings(read ? readHz_ : writeHz_, MSBFIRST, SPI_MODE0));
    digitalWrite(cs_, LOW);
  }

  void write(const uint8_t* data, size_t len) override {
    while (len > 0) {
      size_t n = len < kChunk ? len : kChunk;
      waitNotBusy();
      // SPIClass::transfer(buf, n) overwrites buf with the received bytes
      memcpy(scratch_, data, n);
      spi_.transfer(scratch_, n);
      data += n;
      len -= n;
    }
  }

  void read(uint8_t* data, size_t len) override {
    for (size_t i = 0; i < len; ++i) data[i] = spi_.transfer(0x00);
  }

  void endTransaction() override {
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
  }

  bool hasBusyPin() const override { return busy_ >= 0; }
  uint32_t millis() override { return ::millis(); }
  void delayMicros(uint32_t us) override { delayMicroseconds(us); }

 protected:
  SPIClass& spi_;
  int cs_;
  int busy_;
  uint32_t writeHz_;
  uint32_t readHz_;
  uint8_t scratch_[kChunk];

  void waitNotBusy() {
    if (busy_ < 0) return;
    while (digitalRead(busy_) == HIGH) {
    }
  }
};

}  // namespace tangnanogpu
