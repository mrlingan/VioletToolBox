#ifndef VIOLET_NATIVE_H
#define VIOLET_NATIVE_H
#include <stdint.h>
#include <stddef.h>
int violet_decompress(int type, const uint8_t *input, size_t input_size,
                      uint8_t *output, size_t capacity, size_t *written);
typedef int (*violet_progress)(void *context, int64_t done, int64_t total);
int violet_extract_payload(const char *source, const char *destination,
                           violet_progress callback, void *context, char *error, size_t error_size);
void *violet_cfb_create(const uint8_t *key, const uint8_t *iv);
int violet_cfb_update(void *context, const uint8_t *input, size_t length,
                      uint8_t *output, size_t capacity, size_t *written);
int violet_cfb_finish(void *context, uint8_t *output, size_t capacity, size_t *written);
void violet_cfb_free(void *context);
int violet_aes256_ctr(const uint8_t *key, const uint8_t *iv, const uint8_t *input,
                     size_t length, uint8_t *output, size_t capacity, size_t *written);
void *violet_ops_create(int version, uint64_t length);
int violet_ops_update(void *context, const uint8_t *input, uint8_t *output, size_t count);
void violet_ops_free(void *context);
uint32_t violet_crc32(uint32_t previous, const uint8_t *bytes, size_t length);
uint32_t violet_crc32_zeros(uint32_t previous, uint64_t length);
void *violet_inflate_create(void);
int violet_inflate_update(void *context, const uint8_t *input, size_t length,
                          uint8_t *output, size_t capacity, size_t *consumed, size_t *written);
void violet_inflate_free(void *context);
int violet_module_prop(const char *source, uint8_t *output, size_t capacity,
                       size_t *written, char *error, size_t error_size);
int violet_zip_member(const char *source, const char *member, uint8_t *output, size_t capacity,
                      size_t *written, char *error, size_t error_size);
#endif
