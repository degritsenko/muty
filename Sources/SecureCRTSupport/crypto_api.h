#ifndef MUTY_SECURECRT_CRYPTO_API_H
#define MUTY_SECURECRT_CRYPTO_API_H
#include <CommonCrypto/CommonDigest.h>
#define crypto_hash_sha512_BYTES CC_SHA512_DIGEST_LENGTH
static inline int crypto_hash_sha512(unsigned char *out, const void *in, size_t length) {
    return CC_SHA512(in, (CC_LONG)length, out) == NULL ? -1 : 0;
}
#endif
