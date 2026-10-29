#include "VioletNative.h"
#include "CZstdDecoder.h"
#include <bzlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>

// macOS ships these libraries and link stubs, but not their public headers.
// Only stable, opaque C entry points are declared here; no private Apple APIs.
// XZ: https://tukaani.org/xz/liblzma-api/container_8h.html
extern int lzma_stream_buffer_decode(uint64_t *, uint32_t, const void *,
    const uint8_t *, size_t *, size_t, uint8_t *, size_t *, size_t);
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern const char *archive_entry_pathname(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern const char *archive_error_string(struct archive *);
extern int archive_read_free(struct archive *);
extern unsigned int archive_entry_filetype(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);

int violet_zip_member(const char *source, const char *member, uint8_t *output, size_t capacity,
                      size_t *written, char *error, size_t error_size) {
    struct archive *archive = archive_read_new();
    struct archive_entry *entry = NULL;
    int result = -1, found = 0, status = 0, entries = 0;
    *written = 0;
    if (!archive) return -1;
    archive_read_support_format_zip(archive);
    if (archive_read_open_filename(archive, source, 65536) != 0) goto failure;
    while ((status = archive_read_next_header(archive, &entry)) == 0) {
        if (++entries > 100000) { snprintf(error, error_size, "ZIP 文件条目过多"); goto cleanup; }
        const char *name = archive_entry_pathname(entry);
        if (!name || strcmp(name, member) != 0) continue;
        if (found++ || archive_entry_filetype(entry) != 0100000 || archive_entry_is_encrypted(entry) > 0 ||
            archive_entry_size(entry) <= 0 || (uint64_t)archive_entry_size(entry) > capacity) {
            snprintf(error, error_size, "ZIP 条目重复、加密、非普通文件或超过读取限制"); goto cleanup;
        }
        ssize_t count;
        while (*written < capacity && (count = archive_read_data(archive, output + *written, capacity - *written)) > 0)
            *written += (size_t)count;
        uint8_t extra;
        if (archive_read_data(archive, &extra, 1) != 0 || *written != (size_t)archive_entry_size(entry)) goto failure;
    }
    if (status != 1) goto failure; // ARCHIVE_EOF
    if (!found) { snprintf(error, error_size, "ZIP 中缺少所需条目：%s", member); result = 1; goto cleanup; }
    result = 0;
    goto cleanup;
failure:
    snprintf(error, error_size, "%s", archive_error_string(archive) ?: "模块 ZIP 不完整或校验失败");
cleanup:
    archive_read_free(archive);
    return result;
}

int violet_module_prop(const char *source, uint8_t *output, size_t capacity,
                       size_t *written, char *error, size_t error_size) {
    return violet_zip_member(source, "module.prop", output, capacity, written, error, error_size);
}

int violet_decompress(int type, const uint8_t *input, size_t input_size,
                      uint8_t *output, size_t capacity, size_t *written) {
    *written = 0;
    if (type == 1) {
        if (input_size > UINT32_MAX || capacity > UINT32_MAX) return -1;
        unsigned int count = (unsigned int)capacity;
        int result = BZ2_bzBuffToBuffDecompress((char *)output, &count, (char *)input,
                                              (unsigned int)input_size, 0, 0);
        *written = count;
        return result;
    }
    if (type == 8) {
        uint64_t limit = 256ULL * 1024 * 1024;
        size_t position = 0;
        int result = lzma_stream_buffer_decode(&limit, 0, NULL, input, &position,
                                               input_size, output, written, capacity);
        return result == 0 && position != input_size ? -2 : result;
    }
    if (type == 14) return violet_zstd_decode(input, input_size, output, capacity, written);
    return -3;
}

int violet_extract_payload(const char *source, const char *destination,
                           violet_progress callback, void *context, char *error, size_t error_size) {
    int result = -1, fd = -1;
    struct archive *archive = archive_read_new();
    struct archive_entry *entry = NULL;
    uint8_t *buffer = NULL;
    if (!archive) { snprintf(error, error_size, "无法初始化 ZIP 读取器"); return -1; }
    archive_read_support_format_zip(archive);
    archive_read_support_filter_all(archive);
    if (archive_read_open_filename(archive, source, 1024 * 1024) != 0) goto failure;
    int found = 0;
    while (archive_read_next_header(archive, &entry) == 0) {
        if (callback && callback(context, 0, 0)) { result = -2; goto cleanup; }
        const char *name = archive_entry_pathname(entry);
        if (!name) continue;
        const char *base = strrchr(name, '/');
        if (strcmp(base ? base + 1 : name, "payload.bin") == 0) { found = 1; break; }
    }
    if (!found) { snprintf(error, error_size, "OTA ZIP 内没有 payload.bin，或 ZIP 目录已损坏"); goto cleanup; }
    int64_t total = archive_entry_size(entry), done = 0;
    if (total <= 0 || total > (1LL << 40)) { snprintf(error, error_size, "ZIP 中的 payload 大小异常"); goto cleanup; }
    fd = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { snprintf(error, error_size, "无法创建临时 payload 文件"); goto cleanup; }
    buffer = malloc(1024 * 1024);
    if (!buffer) { snprintf(error, error_size, "内存不足"); goto cleanup; }
    ssize_t count;
    while ((count = archive_read_data(archive, buffer, 1024 * 1024)) > 0) {
        if (count > total - done) { snprintf(error, error_size, "ZIP 解压长度超出声明大小"); goto cleanup; }
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t written = write(fd, buffer + offset, (size_t)count - offset);
            if (written <= 0) { snprintf(error, error_size, "写入失败，请检查剩余磁盘空间"); goto cleanup; }
            offset += (size_t)written;
        }
        done += count;
        if (callback && callback(context, done, total)) { result = -2; goto cleanup; }
    }
    if (count < 0) goto failure;
    if (done != total) { snprintf(error, error_size, "ZIP 解压数据不完整"); goto cleanup; }
    result = 0;
    goto cleanup;
failure:
    snprintf(error, error_size, "%s", archive_error_string(archive) ?: "ZIP 读取失败");
cleanup:
    if (fd >= 0) close(fd);
    if (result != 0 && fd >= 0) unlink(destination);
    free(buffer);
    archive_read_free(archive);
    return result;
}
