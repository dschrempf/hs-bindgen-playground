#include <stddef.h>

#define MASK   (1u << 31)
#define ADD(x) ((x) + 4)

struct blinds {
  char window_id;
  int  tilt : 1;
  int  close_blinds : 1;
  long timestamp;
};

struct surname {
  size_t len;
  char   data[];
};
