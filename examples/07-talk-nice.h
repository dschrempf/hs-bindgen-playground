#include <stddef.h>

typedef double scalar;

typedef struct {
  scalar x;
  scalar y;
} vector;

typedef enum { LINEAR, CUBIC } interp;

vector vector_add(vector a, vector b);
void   vector_map(vector *vs, size_t n, scalar (*f)(scalar));

#define VEC_VERSION 2
#define VEC_EPSILON 1e-9
