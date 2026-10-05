#pragma once
#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace tangnanogpu {

/**
 * @brief Byte transport to the TangNanoGPU board.
 *
 * One transaction = one chip-select period. Implementations:
 * - TransportSPI (Arduino SPIClass + chip select + BUSY pin)
 * - TransportRecorder (desktop / tests: records every transaction)
 */
class ITransport {
 public:
  virtual ~ITransport() = default;
  virtual bool begin() { return true; }
  virtual void end() {}

  /// Starts a transaction. `read` selects the slower read clock, needed
  /// whenever MISO data is used (PING/STATUS/READ_DATA).
  virtual void beginTransaction(bool read) = 0;
  /// Sends bytes; implementations wait on BUSY between chunks so a long
  /// payload never overruns the command FIFO.
  virtual void write(const uint8_t* data, size_t len) = 0;
  /// Clocks out zeros and stores what arrives on MISO.
  virtual void read(uint8_t* data, size_t len) = 0;
  virtual void endTransaction() = 0;

  /// True if the transport can see the BUSY pin, so payloads of any length
  /// are safe in one transaction.
  virtual bool hasBusyPin() const = 0;

  /// Time helpers (millis-style), used for timeouts.
  virtual uint32_t millis() = 0;
  virtual void delayMicros(uint32_t us) = 0;
};

/**
 * @brief Transport that only records transactions (no hardware).
 *
 * Used by the desktop golden-model test (tools/golden) and unit tests:
 * every transaction is stored as a byte vector; reads return
 * `readValue()`-filled bytes. Behaves as if the board had a BUSY pin.
 */
class TransportRecorder : public ITransport {
 public:
  void beginTransaction(bool) override { current_.clear(); }
  void write(const uint8_t* data, size_t len) override {
    current_.insert(current_.end(), data, data + len);
  }
  void read(uint8_t* data, size_t len) override {
    for (size_t i = 0; i < len; ++i) {
      data[i] = readValue_;
      current_.push_back(0);
    }
  }
  void endTransaction() override { transactions_.push_back(current_); }
  bool hasBusyPin() const override { return true; }
  uint32_t millis() override { return ++fakeMillis_; }
  void delayMicros(uint32_t) override {}

  /// Value returned for every byte read.
  void setReadValue(uint8_t v) { readValue_ = v; }
  const std::vector<std::vector<uint8_t>>& transactions() const { return transactions_; }
  void clear() { transactions_.clear(); }

 protected:
  std::vector<uint8_t> current_;
  std::vector<std::vector<uint8_t>> transactions_;
  uint8_t readValue_ = 0;
  uint32_t fakeMillis_ = 0;
};

}  // namespace tangnanogpu
