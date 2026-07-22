/* Fixed-width types from <stdint.h>: map to sized Haskell types (Word32, Int64, ...). */
#include <stdint.h>

struct Header {
  uint32_t magic;
  uint16_t version;
  int64_t  timestamp;
  uint8_t  flags;
};
