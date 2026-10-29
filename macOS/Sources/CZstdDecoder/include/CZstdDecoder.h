#ifndef VIOLET_ZSTD_DECODER_H
#define VIOLET_ZSTD_DECODER_H
#include <stddef.h>
int violet_zstd_decode(const void *input, size_t length, void *output,
                       size_t capacity, size_t *written);
#endif
