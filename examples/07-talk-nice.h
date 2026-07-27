#include <stddef.h>

#define VEC_VERSION 2
#define VEC_EPSILON 1e-9

typedef struct {
    double x;
    double y;
} vector;

typedef enum { LINEAR, CUBIC } interp;

typedef double scalar;

scalar  vector_length(vector v);
vector  vector_add(vector a, vector b);
vector *vector_new(double x, double y);
void    vector_map(vector *vs, size_t n, double (*f)(double));
