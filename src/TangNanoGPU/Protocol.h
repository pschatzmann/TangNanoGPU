#pragma once
#include <stddef.h>
#include <stdint.h>

namespace tangnanogpu {

/// Opcodes of the TangNanoGPU SPI protocol - see docs/protocol.md.
/// Every SPI transaction is [address][opcode][payload...].
namespace op {
// immediate (answered by the SPI slave itself)
constexpr uint8_t kPing = 0x01;
constexpr uint8_t kReset = 0x02;
constexpr uint8_t kStatus = 0x03;
constexpr uint8_t kReadData = 0x51;
// queued (executed in order by the drawing engine)
constexpr uint8_t kSetTarget = 0x10;
constexpr uint8_t kShow = 0x11;
constexpr uint8_t kWaitVSync = 0x12;
constexpr uint8_t kSetClip = 0x13;
constexpr uint8_t kFillRect = 0x20;
constexpr uint8_t kLine = 0x21;
constexpr uint8_t kPixels = 0x22;
constexpr uint8_t kCircle = 0x23;
constexpr uint8_t kWriteRect = 0x30;
constexpr uint8_t kUpload = 0x31;
constexpr uint8_t kCopyRect = 0x32;
constexpr uint8_t kMask = 0x40;
constexpr uint8_t kReadRect = 0x50;
}  // namespace op

/// Framebuffer geometry (fixed by the gateware).
constexpr int kWidth = 320;
constexpr int kHeight = 240;
/// SDRAM rows (one row = 512 pixels) used by the two framebuffers; image
/// storage for uploadImage()/blit() starts at kImageRowBase.
constexpr uint16_t kFrameBufferRow[2] = {0, 256};
constexpr uint16_t kImageRowBase = 512;
constexpr uint16_t kImageRowEnd = 8192;
/// Max pixels per image row (one SDRAM row)
constexpr int kMaxImageWidth = 512;
/// Command FIFO / response FIFO sizes (bytes usable)
constexpr size_t kCmdFifoBytes = 4095;
constexpr size_t kRespFifoBytes = 2047;

/// STATUS flag bits
namespace gpuflag {
constexpr uint8_t kBusy = 0x01;        ///< engine executing or commands queued
constexpr uint8_t kFrontBuffer = 0x02; ///< buffer currently on screen
constexpr uint8_t kOverflow = 0x04;    ///< command bytes were dropped (sticky)
constexpr uint8_t kBadOpcode = 0x08;   ///< stream desynchronised (sticky) - reset()
constexpr uint8_t kSdramReady = 0x10;
constexpr uint8_t kTarget = 0x20;      ///< buffer being drawn into
constexpr uint8_t kLate = 0x40;        ///< scanout missed a line (sticky)
}  // namespace gpuflag

/// Little helper that assembles one command into a fixed buffer.
class CommandBuilder {
 public:
  CommandBuilder(uint8_t* buf, uint8_t address) : buf_(buf) { buf_[len_++] = address; }

  CommandBuilder& u8(uint8_t v) {
    buf_[len_++] = v;
    return *this;
  }
  /// int16/uint16, little endian
  CommandBuilder& u16(uint16_t v) {
    buf_[len_++] = static_cast<uint8_t>(v & 0xff);
    buf_[len_++] = static_cast<uint8_t>(v >> 8);
    return *this;
  }
  CommandBuilder& i16(int v) { return u16(static_cast<uint16_t>(static_cast<int16_t>(v))); }
  /// Colour in TinyGPU's stored RGB565 representation (getValue()): sent
  /// in memory order, i.e. the conventional RGB565's high byte first.
  CommandBuilder& color(uint16_t storedValue) {
    buf_[len_++] = static_cast<uint8_t>(storedValue & 0xff);
    buf_[len_++] = static_cast<uint8_t>(storedValue >> 8);
    return *this;
  }
  size_t size() const { return len_; }
  const uint8_t* data() const { return buf_; }

 protected:
  uint8_t* buf_;
  size_t len_ = 0;
};

}  // namespace tangnanogpu
