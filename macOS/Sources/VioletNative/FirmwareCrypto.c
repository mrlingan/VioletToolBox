#include "VioletNative.h"
#include <CommonCrypto/CommonCryptor.h>
#include <zlib.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

void *violet_cfb_create(const uint8_t *key, const uint8_t *iv) {
    CCCryptorRef cryptor = NULL;
    if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeCFB, kCCAlgorithmAES,
        ccNoPadding, iv, key, 16, NULL, 0, 0, 0, &cryptor) != kCCSuccess) return NULL;
    return cryptor;
}
int violet_cfb_update(void *context, const uint8_t *input, size_t length,
                      uint8_t *output, size_t capacity, size_t *written) {
    return CCCryptorUpdate(context, input, length, output, capacity, written);
}
int violet_cfb_finish(void *context, uint8_t *output, size_t capacity, size_t *written) {
    return CCCryptorFinal(context, output, capacity, written);
}
void violet_cfb_free(void *context) { if (context) CCCryptorRelease(context); }
int violet_aes256_ctr(const uint8_t *key, const uint8_t *iv, const uint8_t *input,
                     size_t length, uint8_t *output, size_t capacity, size_t *written) {
    CCCryptorRef cryptor = NULL;
    size_t updated = 0, final = 0;
    if (!key || !iv || !input || !output || !written || capacity < length)
        return kCCParamError;
    *written = 0;
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR,
        kCCAlgorithmAES, ccNoPadding, iv, key, 32, NULL, 0, 0,
        kCCModeOptionCTR_BE, &cryptor);
    if (status != kCCSuccess) return status;
    status = CCCryptorUpdate(cryptor, input, length, output, capacity, &updated);
    if (status == kCCSuccess)
        status = CCCryptorFinal(cryptor, output + updated, capacity - updated, &final);
    CCCryptorRelease(cryptor);
    if (status == kCCSuccess) *written = updated + final;
    return status;
}
uint32_t violet_crc32(uint32_t previous, const uint8_t *bytes, size_t length) {
    return (uint32_t)crc32(previous, bytes, (unsigned int)length);
}
uint32_t violet_crc32_zeros(uint32_t previous, uint64_t length) {
    const uint8_t zero=0;
    uint32_t zeros=(uint32_t)crc32(0,&zero,1);
    z_off_t span=1;
    while(length) {
        if(length&1) previous=(uint32_t)crc32_combine(previous,zeros,span);
        length>>=1;
        if(length) { zeros=(uint32_t)crc32_combine(zeros,zeros,span); span*=2; }
    }
    return previous;
}

void *violet_inflate_create(void) {
    z_stream *stream = calloc(1, sizeof(*stream));
    if (!stream) return NULL;
    if (inflateInit2(stream, -MAX_WBITS) != Z_OK) { free(stream); return NULL; }
    return stream;
}
int violet_inflate_update(void *context, const uint8_t *input, size_t length,
                          uint8_t *output, size_t capacity, size_t *consumed, size_t *written) {
    if (!context || (!input && length) || !output || !consumed || !written ||
        length > UINT_MAX || !capacity || capacity > UINT_MAX) return -1;
    z_stream *stream = context;
    stream->next_in = (Bytef *)input; stream->avail_in = (uInt)length;
    stream->next_out = output; stream->avail_out = (uInt)capacity;
    int status = inflate(stream, Z_NO_FLUSH);
    *consumed = length - stream->avail_in;
    *written = capacity - stream->avail_out;
    if (status == Z_STREAM_END) return 1;
    return status == Z_OK || status == Z_BUF_ERROR ? 0 : -1;
}
void violet_inflate_free(void *context) {
    if (context) { inflateEnd(context); free(context); }
}

// Adapted from VioletToolBox/OnePlusOpsExtractor.cs. Algorithm attribution:
// B. Kerler, opscrypto.py (2019-2022, MIT); see macOS/NOTICE.md.
static const uint8_t aes_sbox[256] = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};
typedef struct {
    uint32_t key[4];
    uint8_t table[2048], mbox[64];
    uint64_t remaining;
    int use_mbox;
} ops_context;
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint32_t gs(ops_context *ctx, uint32_t index, int shift) {
    return le32(ctx->table + ((index & 255) * 8) + shift);
}
static void update_key(ops_context *ctx) {
    const uint8_t *k = ctx->use_mbox ? ctx->mbox : ctx->table;
    uint32_t d=ctx->key[0]^k[0], a=ctx->key[1]^k[1], b=ctx->key[2]^k[2], c=ctx->key[3]^k[3];
    uint32_t e=gs(ctx,b>>16,2)^gs(ctx,a>>8,3)^gs(ctx,c>>24,1)^gs(ctx,d,0)^k[4];
    uint32_t h=gs(ctx,c>>16,2)^gs(ctx,b>>8,3)^gs(ctx,d>>24,1)^gs(ctx,a,0)^k[5];
    uint32_t i=gs(ctx,d>>16,2)^gs(ctx,c>>8,3)^gs(ctx,a>>24,1)^gs(ctx,b,0)^k[6];
    a=gs(ctx,d>>8,3)^gs(ctx,a>>16,2)^gs(ctx,b>>24,1)^gs(ctx,c,0)^k[7];
    int g=8;
    for (int round=0; round < k[60]-2; round++,g+=4) {
        uint32_t oe=e, oh=h, oi=i, oa=a;
        e=gs(ctx,oi>>16,2)^gs(ctx,oh>>8,3)^gs(ctx,oa>>24,1)^gs(ctx,oe,0)^k[g];
        h=gs(ctx,oa>>16,2)^gs(ctx,oi>>8,3)^gs(ctx,oe>>24,1)^gs(ctx,oh,0)^k[g+1];
        i=gs(ctx,oe>>16,2)^gs(ctx,oa>>8,3)^gs(ctx,oh>>24,1)^gs(ctx,oi,0)^k[g+2];
        a=gs(ctx,oe>>8,3)^gs(ctx,oh>>16,2)^gs(ctx,oi>>24,1)^gs(ctx,oa,0)^k[g+3];
    }
    ctx->key[0]=(gs(ctx,i>>16,0)&0x00ff0000)^(gs(ctx,h>>8,1)&0x0000ff00)^(gs(ctx,a>>24,3)&0xff000000)^(gs(ctx,e,2)&255)^k[g];
    ctx->key[1]=(gs(ctx,a>>16,0)&0x00ff0000)^(gs(ctx,i>>8,1)&0x0000ff00)^(gs(ctx,e>>24,3)&0xff000000)^(gs(ctx,h,2)&255)^k[g+3];
    ctx->key[2]=(gs(ctx,e>>16,0)&0x00ff0000)^(gs(ctx,a>>8,1)&0x0000ff00)^(gs(ctx,h>>24,3)&0xff000000)^(gs(ctx,i,2)&255)^k[g+2];
    ctx->key[3]=(gs(ctx,h>>16,0)&0x00ff0000)^(gs(ctx,e>>8,1)&0x0000ff00)^(gs(ctx,i>>24,3)&0xff000000)^(gs(ctx,a,2)&255)^k[g+1];
}
void *violet_ops_create(int version, uint64_t length) {
    static const uint8_t constants[3][16]={
        {0xc4,0x5d,0x05,0x71,0x99,0xdd,0xbb,0xee,0x29,0xa1,0x6d,0xc7,0xad,0xbf,0xa4,0x3f},
        {0x60,0x8a,0x3f,0x2d,0x68,0x6b,0xd4,0x23,0x51,0x0c,0xd0,0x95,0xbb,0x40,0xe9,0x76},
        {0xaa,0x69,0x82,0x9e,0x5d,0xde,0xb1,0x3d,0x30,0xbb,0x81,0xa3,0x46,0x65,0xa3,0xe1}
    };
    if (version<4 || version>6) return NULL;
    ops_context *ctx=calloc(1,sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->key[0]=0x9ee3b5d1; ctx->key[1]=0x9d04ea5e; ctx->key[2]=0xabd51d67; ctx->key[3]=0xafcbafd2;
    memcpy(ctx->mbox,constants[version-4],16); ctx->mbox[60]=10;
    for (int n=0;n<256;n++) {
        uint8_t value=aes_sbox[n], doubled=(uint8_t)((value<<1)^((value&128)?0x1b:0));
        uint8_t entry[4]={doubled,value,value,(uint8_t)(doubled^value)};
        memcpy(ctx->table+n*8,entry,4); memcpy(ctx->table+n*8+4,entry,4);
    }
    ctx->remaining=length; ctx->use_mbox=length>15;
    return ctx;
}
int violet_ops_update(void *context,const uint8_t *input,uint8_t *output,size_t count) {
    ops_context *ctx=context;
    if (!ctx || count>ctx->remaining || (count<ctx->remaining && count%16!=0)) return -1;
    size_t position=0;
    while(position<count) {
        size_t block=count-position<16?count-position:16;
        uint8_t padded[16]={0}; memcpy(padded,input+position,block);
        update_key(ctx);
        for(int word=0;word<4;word++) {
            uint32_t encrypted=le32(padded+word*4), plain=encrypted^ctx->key[word];
            for(int byte=0;byte<4;byte++) {
                size_t offset=(size_t)word*4+byte;
                if(offset<block) output[position+offset]=(uint8_t)(plain>>(byte*8));
            }
            ctx->key[word]=encrypted;
        }
        position+=block;
    }
    ctx->remaining-=count;
    return 0;
}
void violet_ops_free(void *context) { if(context) { memset(context,0,sizeof(ops_context)); free(context); } }
