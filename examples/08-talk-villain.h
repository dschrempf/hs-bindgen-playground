#include <stddef.h>

#define SQUARE(x) ((x) * (x))
#define MASK (1u << 31)
#define TWO_G (2 * 1024 * 1024 * 1024)

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

struct square;
struct square *create_square(double side);
