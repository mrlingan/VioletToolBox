/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Narrow block I/O front end for the pinned BSD-3-Clause linux-msm/qdl API.
 * Never selects the first device, provisions storage, or resets on close. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libxml/parser.h>
#include "qdl.h"
#include "programmer.h"
#include "firehose.h"
#include "ux.h"
#include "program.h"
#include "patch.h"

bool qdl_debug = false;

static bool number(const char *s, uint64_t *value)
{
    if (!s || !*s) return false;
    for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9') return false;
    errno = 0;
    *value = strtoull(s, NULL, 10);
    return errno == 0;
}

static void json_string(const char *s)
{
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static bool unique_device(const char *serial)
{
    unsigned int count = 0, matches = 0;
    struct qdl_device_desc *devices = usb_list(&count);
    if (!serial || !*serial || strlen(serial) > 256) { free(devices); return false; }
    for (unsigned int i = 0; i < count; ++i)
        if (!strcmp(devices[i].serial, serial)) ++matches;
    free(devices);
    if (matches != 1) fprintf(stderr, "Expected exactly one USB EDL device with this serial; found %u\n", matches);
    return matches == 1;
}

static bool geometry(struct qdl_device *device, unsigned int lun, size_t *sector, size_t *count)
{
    if (firehose_getsize(device, lun, sector, count) < 0) return false;
    return *sector >= 512 && *sector <= 65536 && !(*sector & (*sector - 1)) &&
           *count > 0 && *count <= INT64_MAX / *sector;
}

static int block_file(struct qdl_device *device, bool writing, unsigned int lun,
                      size_t sector, size_t start, size_t count, const char *filename)
{
    int fd = open(filename, (writing ? O_RDONLY : O_WRONLY | O_TRUNC) | O_NOFOLLOW);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 0) {
        if (fd >= 0) close(fd);
        fprintf(stderr, "Block I/O requires an existing regular staging file\n");
        return -1;
    }
    const uint64_t bytes = (uint64_t)count * sector, source_bytes = info.st_size;
    if (writing && (!source_bytes || source_bytes > bytes || (source_bytes + sector - 1) / sector != count)) {
        fprintf(stderr, "Input length does not match the declared sector range\n");
        close(fd); return -1;
    }
    size_t chunk_sectors = (8 * 1024 * 1024) / sector;
    unsigned char *buffer = malloc(chunk_sectors * sector);
    if (!buffer) { close(fd); return -1; }
    size_t done = 0;
    int status = -1;
    while (done < count) {
        size_t sectors = count - done < chunk_sectors ? count - done : chunk_sectors;
        size_t length = sectors * sector;
        ssize_t transferred;
        if (writing) {
            memset(buffer, 0, length);
            uint64_t offset = (uint64_t)done * sector;
            size_t needed = source_bytes - offset < length ? source_bytes - offset : length;
            size_t loaded = 0;
            while (loaded < needed) {
                ssize_t got = read(fd, buffer + loaded, needed - loaded);
                if (got < 0 && errno == EINTR) continue;
                if (got <= 0) goto out;
                loaded += got;
            }
            transferred = firehose_pwrite(device, lun, start + done, buffer, sector, sectors);
        } else {
            transferred = firehose_pread(device, lun, start + done, buffer, sector, sectors);
            if (transferred == (ssize_t)length) {
                size_t saved = 0;
                while (saved < length) {
                    ssize_t sent = write(fd, buffer + saved, length - saved);
                    if (sent < 0 && errno == EINTR) continue;
                    if (sent <= 0) goto out;
                    saved += sent;
                }
            }
        }
        if (transferred != (ssize_t)length) goto out;
        done += sectors;
        fprintf(stderr, "VIOLET_EDL_PROGRESS\t%" PRIu64 "\t%" PRIu64 "\n", (uint64_t)done * sector, bytes);
    }
    if (!writing && fsync(fd)) goto out;
    status = 0;
out:
    free(buffer); close(fd);
    return status;
}

static int erase_blocks(struct qdl_device *device, unsigned int lun, size_t sector,
                        uint64_t start, uint64_t count)
{
    while (count) {
        struct list_head ops = LIST_INIT(ops);
        struct firehose_op *op = firehose_alloc_op(FIREHOSE_OP_ERASE);
        if (!op) return -1;
        unsigned int batch = count > UINT_MAX ? UINT_MAX : (unsigned int)count;
        char position[32];
        snprintf(position, sizeof(position), "%" PRIu64, start);
        op->partition = lun; op->sector_size = sector;
        op->num_sectors = batch; op->start_sector = strdup(position);
        if (!op->start_sector) { free(op); return -1; }
        list_append(&ops, &op->node);
        int result = firehose_run(device, &ops);
        firehose_free_ops(&ops);
        if (result < 0) return -1;
        start += batch; count -= batch;
    }
    return 0;
}

static int verify_file(struct qdl_device *device, unsigned int lun, size_t sector,
                       size_t start, size_t count, const char *filename)
{
    int fd = open(filename, O_RDONLY | O_NOFOLLOW), status = -1;
    if (fd < 0) return -1;
    size_t chunk = (8 * 1024 * 1024) / sector;
    unsigned char *expected = malloc(chunk * sector), *actual = malloc(chunk * sector);
    if (!expected || !actual) goto out;
    for (size_t done = 0; done < count;) {
        size_t sectors = count - done < chunk ? count - done : chunk, bytes = sectors * sector, loaded = 0;
        while (loaded < bytes) {
            ssize_t got = read(fd, expected + loaded, bytes - loaded);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) goto out;
            loaded += got;
        }
        if (firehose_pread(device, lun, start + done, actual, sector, sectors) != (ssize_t)bytes || memcmp(expected, actual, bytes)) {
            fprintf(stderr, "GPT readback mismatch on LUN %u at sector %zu\n", lun, start + done); goto out;
        }
        done += sectors;
    }
    status = 0;
out:
    free(expected); free(actual); close(fd); return status;
}

static bool xml_number(xmlNode *node, const char *key, uint64_t *value)
{
    xmlChar *text = xmlGetProp(node, (const xmlChar *)key);
    bool result = number((const char *)text, value);
    xmlFree(text); return result;
}

static bool image_path(xmlNode *node, const char *key, const char *base, char *path)
{
    xmlChar *text = xmlGetProp(node, (const xmlChar *)key);
    bool ok = false;
    if (!text || !*text || strlen((const char *)text) > 255 || strchr((const char *)text, '/') ||
        strchr((const char *)text, '\\') || !strcmp((const char *)text, ".") || !strcmp((const char *)text, "..")) goto out;
    for (const xmlChar *p = text; *p; ++p) if (*p < 32) goto out;
    ok = snprintf(path, PATH_MAX, "%s/%s", base, text) < PATH_MAX;
out:
    xmlFree(text); return ok;
}

static bool image_sectors(const char *path, size_t sector, size_t *count)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    struct stat info;
    bool ok = fd >= 0 && !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_size > 0 &&
              info.st_size <= 64 * 1024 * 1024 && info.st_size % sector == 0;
    if (ok) *count = info.st_size / sector;
    if (fd >= 0) close(fd); return ok;
}

static int set_bootable(struct qdl_device *device, unsigned int value)
{
    struct list_head ops = LIST_INIT(ops);
    struct firehose_op *op = firehose_alloc_op(FIREHOSE_OP_SET_BOOTABLE);
    if (!op) return -1;
    op->partition = value; list_append(&ops, &op->node);
    int result = firehose_run(device, &ops);
    firehose_free_ops(&ops); return result;
}

static int write_gpt_transaction(struct qdl_device *device, const char *manifest)
{
    struct volume { uint64_t lun, sector, total, backup_start; size_t main_count, backup_count; char main[PATH_MAX], backup[PATH_MAX]; } volumes[32];
    unsigned int count = 0;
    uint64_t bootable = 0;
    bool change_bootable = false;
    int status = -1;
    char base[PATH_MAX];
    if (strlen(manifest) >= sizeof(base)) return -1;
    strcpy(base, manifest);
    char *slash = strrchr(base, '/');
    if (!slash) return -1;
    *slash = '\0';
    xmlDoc *doc = xmlReadFile(manifest, NULL, XML_PARSE_NONET);
    if (!doc || doc->intSubset || doc->extSubset) goto out;
    xmlNode *root = xmlDocGetRootElement(doc);
    if (!root || xmlStrcmp(root->name, (const xmlChar *)"violet_gpt_transaction")) goto out;
    if (xmlHasProp(root, (const xmlChar *)"bootable")) {
        if (!xml_number(root, "bootable", &bootable) || bootable > 255) goto out;
        change_bootable = true;
    }
    /* All inputs and all LUN geometries are checked before the first write. */
    for (xmlNode *node = root->children; node; node = node->next) {
        if (node->type != XML_ELEMENT_NODE) continue;
        if (xmlStrcmp(node->name, (const xmlChar *)"volume") || count >= 32) goto out;
        struct volume *v = &volumes[count];
        size_t sector = 0, total = 0;
        if (!xml_number(node, "lun", &v->lun) || v->lun > 255 || !xml_number(node, "sector", &v->sector) ||
            !xml_number(node, "total", &v->total) || !xml_number(node, "backup_start", &v->backup_start) ||
            !geometry(device, v->lun, &sector, &total) || v->sector != sector || v->total != total ||
            device->max_payload_size < sector || v->backup_start >= total ||
            !image_path(node, "main", base, v->main) || !image_path(node, "backup", base, v->backup) ||
            !image_sectors(v->main, sector, &v->main_count) || !image_sectors(v->backup, sector, &v->backup_count) ||
            v->main_count > v->backup_start || v->backup_count > total - v->backup_start) goto out;
        for (unsigned int i = 0; i < count; ++i) if (volumes[i].lun == v->lun) goto out;
        ++count;
    }
    if (!count) goto out;
    /* Remain in this process through the entire transaction, so the GUI's
     * boundary cancellation cannot leave primary/backup updates half-sent. */
    for (unsigned int i = 0; i < count; ++i) {
        struct volume *v = &volumes[i];
        if (block_file(device, true, v->lun, v->sector, v->backup_start, v->backup_count, v->backup) ||
            verify_file(device, v->lun, v->sector, v->backup_start, v->backup_count, v->backup) ||
            block_file(device, true, v->lun, v->sector, 0, v->main_count, v->main) ||
            verify_file(device, v->lun, v->sector, 0, v->main_count, v->main)) goto out;
    }
    if (change_bootable && set_bootable(device, bootable) < 0) goto out;
    status = 0;
out:
    if (doc) xmlFreeDoc(doc);
    if (status) fprintf(stderr, "GPT transaction did not complete; retain the pre-write backups\n");
    return status;
}

static int flash_xml_transaction(struct qdl_device *device, const char *manifest)
{
    char base[PATH_MAX], path[PATH_MAX];
    struct list_head ops = LIST_INIT(ops);
    uint64_t bootable = 0, allow_security = 0;
    bool activate = false;
    unsigned int luns = 0, files = 0;
    int result = -1;
    if (strlen(manifest) >= sizeof(base)) return -1;
    strcpy(base, manifest);
    char *slash = strrchr(base, '/');
    if (!slash) return -1;
    *slash = '\0';
    xmlDoc *doc = xmlReadFile(manifest, NULL, XML_PARSE_NONET);
    if (!doc || doc->intSubset || doc->extSubset) goto out;
    xmlNode *root = xmlDocGetRootElement(doc);
    if (!root || xmlStrcmp(root->name, (const xmlChar *)"violet_flash_transaction")) goto out;
    if (xmlHasProp(root, (const xmlChar *)"bootable")) {
        if (!xml_number(root, "bootable", &bootable) || bootable > 255) goto out;
        activate = true;
    }
    if (!xml_number(root, "allow_security", &allow_security) || allow_security > 1) goto out;
    /* Parse every canonical file before any storage write, then run the
     * ordered program/erase list followed by the selected DISK patches. */
    for (xmlNode *node = root->children; node; node = node->next) {
        if (node->type != XML_ELEMENT_NODE) continue;
        if (!xmlStrcmp(node->name, (const xmlChar *)"lun")) {
            uint64_t id, expected_sector, expected_total;
            size_t sector, total;
            if (++luns > 32 || !xml_number(node, "id", &id) || id > 255 ||
                !xml_number(node, "sector", &expected_sector) || !xml_number(node, "total", &expected_total) ||
                !geometry(device, id, &sector, &total) || sector != expected_sector || total != expected_total ||
                device->max_payload_size < sector) goto out;
        } else if (!xmlStrcmp(node->name, (const xmlChar *)"file")) {
            if (++files > 256 || !image_path(node, "path", base, path)) goto out;
            xmlChar *type = xmlGetProp(node, (const xmlChar *)"type");
            int status = -1;
            xmlDoc *canonical = xmlReadFile(path, NULL, XML_PARSE_NONET);
            if (canonical && !canonical->intSubset && !canonical->extSubset) {
                if (type && !xmlStrcmp(type, (const xmlChar *)"program")) status = program_load_xml(&ops, canonical, NULL, path, false, false, NULL, NULL);
                else if (type && !xmlStrcmp(type, (const xmlChar *)"patch")) status = patch_load_xml(&ops, canonical, path);
            }
            xmlFree(type); if (canonical) xmlFreeDoc(canonical);
            if (status < 0) goto out;
        } else goto out;
    }
    if (!luns || !files || list_empty(&ops)) goto out;
    if (program_is_sec_partition_flashed(&ops) && !allow_security) {
        fprintf(stderr, "secdata programming requires explicit allow_security\n"); goto out;
    }
    result = firehose_run(device, &ops);
    if (result < 0) goto out;
    if (activate) result = set_bootable(device, bootable);
out:
    firehose_free_ops(&ops);
    if (doc) xmlFreeDoc(doc);
    return result;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "violet-edl geometry|read|write|erase|reset|bootable|gpt-write|xml-flash SERIAL ufs|emmc LOADER [arguments]\n");
        return 2;
    }
    ux_init(); ux_set_color_mode(UX_COLOR_NEVER);
    const char *command = argv[1], *serial = argv[2];
    bool probing = !strcmp(command, "geometry"), reading = !strcmp(command, "read");
    bool writing = !strcmp(command, "write"), erasing = !strcmp(command, "erase"), reset = !strcmp(command, "reset");
    bool gpt_write = !strcmp(command, "gpt-write"), bootable = !strcmp(command, "bootable"), xml_flash = !strcmp(command, "xml-flash");
    if ((!probing && !reading && !writing && !erasing && !reset && !gpt_write && !bootable && !xml_flash) ||
        (probing && (argc < 6 || argc > 37)) ||
        ((reading || writing) && argc != 10) || (erasing && argc != 9) || (reset && argc != 5) || ((gpt_write || bootable || xml_flash) && argc != 6)) return 2;
    enum qdl_storage_type storage = decode_storage_type(argv[3]);
    if (storage != QDL_STORAGE_UFS && storage != QDL_STORAGE_EMMC) return 2;
    uint64_t lun = 0, sector = 0, start = 0, sectors = 0;
    if (bootable && (!number(argv[5], &lun) || lun > 255)) return 2;
    if (!probing && !reset && !gpt_write && !bootable && !xml_flash &&
        (!number(argv[5], &lun) || lun > 255 || !number(argv[6], &sector) ||
         !number(argv[7], &start) || !number(argv[8], &sectors) || !sectors ||
         sector < 512 || sector > 65536 || (sector & (sector - 1)) ||
         sectors > INT64_MAX / sector || start > INT64_MAX / sector)) return 2;
    uint64_t luns[32];
    if (probing) for (int i = 5; i < argc; ++i)
        if (!number(argv[i], &luns[i-5]) || luns[i-5] > 255) return 2;
    if (!unique_device(serial)) return 1;
    struct sahara_image images[MAPPING_SZ] = {};
    char *loader = strdup(argv[4]);
    struct qdl_device *device = NULL;
    bool opened = false;
    int result = -1;
    if (!loader || decode_programmer(loader, images) < 0) goto out;
    device = qdl_init(QDL_DEVICE_USB);
    if (!device) goto out;
    device->slot = UINT_MAX;
    if (usb_open_once(device, serial, NULL) < 0) goto out;
    opened = true;
    if (sahara_run(device, images, NULL, NULL) < 0 || firehose_open(device, storage) < 0) goto out;
    if (reset) { result = firehose_reset(device); goto out; }
    if (bootable) { result = set_bootable(device, lun); goto out; }
    if (gpt_write) { result = write_gpt_transaction(device, argv[5]); goto out; }
    if (xml_flash) { result = flash_xml_transaction(device, argv[5]); goto out; }
    if (probing) {
        struct { uint64_t lun; size_t sector, count; } found[32];
        unsigned int n = 0;
        for (int i = 5; i < argc; ++i) {
            size_t block_size = 0, blocks = 0;
            if (!geometry(device, luns[i-5], &block_size, &blocks)) continue;
            found[n].lun = luns[i-5]; found[n].sector = block_size; found[n++].count = blocks;
        }
        if (!n) { fprintf(stderr, "No valid storage geometry returned\n"); goto out; }
        printf("\nVIOLET_EDL_V1 {\"serial\":"); json_string(serial);
        printf(",\"memory\":"); json_string(argv[3]); printf(",\"luns\":[");
        for (unsigned int i = 0; i < n; ++i)
            printf("%s{\"lun\":%" PRIu64 ",\"sectorSize\":%zu,\"totalSectors\":%zu}", i ? "," : "", found[i].lun, found[i].sector, found[i].count);
        puts("]}"); result = 0; goto out;
    }
    size_t actual_sector = 0, actual_count = 0;
    if (!geometry(device, lun, &actual_sector, &actual_count) || sector != actual_sector || device->max_payload_size < actual_sector ||
        start >= actual_count || sectors > actual_count - start) {
        fprintf(stderr, "Storage geometry or physical range does not match\n"); goto out;
    }
    if (erasing) result = erase_blocks(device, lun, sector, start, sectors);
    else result = block_file(device, writing, lun, sector, start, sectors, argv[9]);
out:
    if (opened) qdl_close(device);
    if (device) qdl_deinit(device);
    sahara_images_free(images, MAPPING_SZ); free(loader);
    return result < 0 ? 1 : 0;
}
