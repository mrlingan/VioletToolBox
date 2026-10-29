#include "CZstdDecoder.h"
#define ZSTD_STATIC_LINKING_ONLY
#include "vendor/zstd.h"

int violet_zstd_decode(const void *input, size_t length, void *output,
                       size_t capacity, size_t *written) {
    const unsigned char *bytes = input;
    const size_t limit = 256U * 1024U * 1024U;
    if (!input || !length || length > limit || !output || !written ||
        !capacity || capacity > limit) return -1;
    *written = 0;
    size_t offset = 0;
    while (offset < length) {
        ZSTD_frameHeader header;
        size_t status = ZSTD_getFrameHeader(&header, bytes + offset, length - offset);
        if (ZSTD_isError(status) || status || header.windowSize > limit || header.dictID)
            return -2;
        size_t frame = ZSTD_findFrameCompressedSize(bytes + offset, length - offset);
        if (ZSTD_isError(frame) || !frame || frame > length - offset) return -3;
        offset += frame;
    }
    ZSTD_DCtx *context = ZSTD_createDCtx();
    if (!context) return -4;
    size_t result = ZSTD_decompressDCtx(context, output, capacity, input, length);
    ZSTD_freeDCtx(context);
    if (ZSTD_isError(result) || result > capacity) return -5;
    *written = result;
    return 0;
}
