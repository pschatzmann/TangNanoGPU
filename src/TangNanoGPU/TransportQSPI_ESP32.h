#pragma once
#if defined(ESP32)
#include <Arduino.h>
#include <string.h>

#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "TangNanoGPU/Protocol.h"
#include "TangNanoGPU/Transport.h"

namespace tangnanogpu {

/**
 * @brief Quad-SPI transport for the ESP32 family (ESP32, -S2, -S3, -P4 ...),
 * built on ESP-IDF's spi_master driver with DMA.
 *
 * Write transactions are quad SPI: the address byte goes out single-line
 * on IO0 with kQuadFlag set (spi_master's command phase), the rest of the
 * transaction on IO3..IO0 (SPI_TRANS_MODE_QIO) - about 4x the bandwidth of
 * TransportSPI at the same clock. Read transactions (PING, STATUS,
 * READ_DATA) use plain single-line SPI at `readHz`.
 *
 * Wiring (see docs/pinout.md): SCK -> FPGA 27, IO0/MOSI -> 28,
 * IO1/MISO <-> 29, CS -> 30, BUSY <- 31, IO2 -> 25, IO3 -> 26.
 * The bitstream must be a quad build (the default); TangNanoGPU::begin()
 * checks this via PING.
 *
 * Uses its own SPI host (default: SPI3_HOST where available, so the
 * Arduino `SPI` object on SPI2/FSPI stays usable) and drives CS itself,
 * so it can wait on BUSY between chunks while CS stays low. On the classic
 * ESP32, clocks above ~26MHz need the SPI host's IO_MUX pins.
 */
class TransportQSPI_ESP32 : public ITransport {
 public:
  static constexpr size_t kChunk = 512;

#if SOC_SPI_PERIPH_NUM > 2
  static constexpr spi_host_device_t kDefaultHost = SPI3_HOST;
#else
  static constexpr spi_host_device_t kDefaultHost = SPI2_HOST;
#endif

  TransportQSPI_ESP32(int sck, int io0, int io1, int io2, int io3, int cs, int busy = -1,
                      uint32_t writeHz = 40000000, uint32_t readHz = 4000000,
                      spi_host_device_t host = kDefaultHost)
      : sck_(sck), io0_(io0), io1_(io1), io2_(io2), io3_(io3), cs_(cs), busy_(busy),
        writeHz_(writeHz), readHz_(readHz), host_(host) {}

  bool begin() override {
    if (ready_) return true;
    pinMode(cs_, OUTPUT);
    digitalWrite(cs_, HIGH);
    if (busy_ >= 0) pinMode(busy_, INPUT);

    spi_bus_config_t bus = {};
    bus.mosi_io_num = io0_;
    bus.miso_io_num = io1_;
    bus.sclk_io_num = sck_;
    bus.quadwp_io_num = io2_;
    bus.quadhd_io_num = io3_;
    bus.max_transfer_sz = kChunk + 16;
    bus.flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_QUAD;
    if (spi_bus_initialize(host_, &bus, SPI_DMA_CH_AUTO) != ESP_OK) return false;

    spi_device_interface_config_t dev = {};
    dev.mode = 0;
    dev.spics_io_num = -1;  // CS driven manually
    dev.queue_size = 1;
    dev.flags = SPI_DEVICE_HALFDUPLEX;
    dev.clock_speed_hz = static_cast<int>(writeHz_);
    if (spi_bus_add_device(host_, &dev, &writeDev_) != ESP_OK) return false;
    dev.clock_speed_hz = static_cast<int>(readHz_);
    if (spi_bus_add_device(host_, &dev, &readDev_) != ESP_OK) return false;

    // DMA-capable bounce buffers (callers' data may live in flash)
    tx_ = static_cast<uint8_t*>(heap_caps_malloc(kChunk, MALLOC_CAP_DMA));
    rx_ = static_cast<uint8_t*>(heap_caps_malloc(kChunk, MALLOC_CAP_DMA));
    ready_ = tx_ != nullptr && rx_ != nullptr;
    return ready_;
  }

  void end() override {
    if (!ready_) return;
    spi_bus_remove_device(writeDev_);
    spi_bus_remove_device(readDev_);
    spi_bus_free(host_);
    heap_caps_free(tx_);
    heap_caps_free(rx_);
    ready_ = false;
  }

  void beginTransaction(bool read) override {
    reading_ = read;
    first_ = true;
    pendingLen_ = 0;
    spi_device_acquire_bus(read ? readDev_ : writeDev_, portMAX_DELAY);
    digitalWrite(cs_, LOW);
  }

  void write(const uint8_t* data, size_t len) override {
    if (reading_) {
      // read transaction: collect the (short) command bytes, they go out
      // together with the read phase in read()
      while (len > 0 && pendingLen_ < sizeof(pending_)) {
        pending_[pendingLen_++] = *data++;
        --len;
      }
      return;
    }
    if (first_ && len > 0) {
      // address byte, single-line, with the quad flag
      first_ = false;
      uint8_t addr = data[0] | kQuadFlag;
      ++data;
      --len;
      size_t n = len < kChunk ? len : kChunk;
      waitNotBusy();
      quadWrite(&addr, data, n);
      data += n;
      len -= n;
    }
    while (len > 0) {
      size_t n = len < kChunk ? len : kChunk;
      waitNotBusy();
      quadWrite(nullptr, data, n);
      data += n;
      len -= n;
    }
  }

  void read(uint8_t* data, size_t len) override {
    bool withCmd = pendingLen_ > 0;
    while (len > 0) {
      size_t n = len < kChunk ? len : kChunk;
      spi_transaction_t t = {};
      if (withCmd) {
        memcpy(tx_, pending_, pendingLen_);
        t.tx_buffer = tx_;
        t.length = pendingLen_ * 8;
        withCmd = false;
        pendingLen_ = 0;
      }
      t.rx_buffer = rx_;
      t.rxlength = n * 8;
      spi_device_polling_transmit(readDev_, &t);
      memcpy(data, rx_, n);
      data += n;
      len -= n;
    }
  }

  void endTransaction() override {
    if (reading_ && pendingLen_ > 0) {
      // write-only command sent on the read device (e.g. none today)
      spi_transaction_t t = {};
      memcpy(tx_, pending_, pendingLen_);
      t.tx_buffer = tx_;
      t.length = pendingLen_ * 8;
      spi_device_polling_transmit(readDev_, &t);
      pendingLen_ = 0;
    }
    digitalWrite(cs_, HIGH);
    spi_device_release_bus(reading_ ? readDev_ : writeDev_);
  }

  bool hasBusyPin() const override { return busy_ >= 0; }
  bool isQuad() const override { return true; }
  uint32_t millis() override { return ::millis(); }
  void delayMicros(uint32_t us) override { delayMicroseconds(us); }

 protected:
  int sck_, io0_, io1_, io2_, io3_, cs_, busy_;
  uint32_t writeHz_, readHz_;
  spi_host_device_t host_;
  spi_device_handle_t writeDev_ = nullptr, readDev_ = nullptr;
  uint8_t* tx_ = nullptr;
  uint8_t* rx_ = nullptr;
  bool ready_ = false, reading_ = false, first_ = true;
  uint8_t pending_[16];
  size_t pendingLen_ = 0;

  /// One spi_master transaction: optional single-line command byte, then
  /// `n` data bytes on IO3..IO0.
  void quadWrite(const uint8_t* cmd, const uint8_t* data, size_t n) {
    spi_transaction_ext_t t = {};
    t.base.flags = SPI_TRANS_VARIABLE_CMD | SPI_TRANS_VARIABLE_ADDR | SPI_TRANS_VARIABLE_DUMMY |
                   (n > 0 ? SPI_TRANS_MODE_QIO : 0);
    t.command_bits = cmd ? 8 : 0;
    t.address_bits = 0;
    t.dummy_bits = 0;
    t.base.cmd = cmd ? *cmd : 0;
    if (n > 0) {
      memcpy(tx_, data, n);
      t.base.tx_buffer = tx_;
      t.base.length = n * 8;
    }
    spi_device_polling_transmit(writeDev_, &t.base);
  }

  void waitNotBusy() {
    if (busy_ < 0) return;
    while (digitalRead(busy_) == HIGH) {
    }
  }
};

}  // namespace tangnanogpu
#endif
