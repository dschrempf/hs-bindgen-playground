#include <stddef.h>

typedef double scalar;

typedef struct {
  scalar x;
  scalar y;
} vector;

typedef enum { LINEAR, CUBIC } interp;

void   vector_map(vector *vs, size_t n, scalar (*f)(scalar));
vector vector_add(vector a, vector b);

#define VEC_VERSION 2
#define VEC_EPSILON 1e-9
