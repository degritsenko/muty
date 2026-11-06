#ifndef MUTY_SECURECRT_SUPPORT_H
#define MUTY_SECURECRT_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
int muty_securecrt_bcrypt_pbkdf(const char *pass, size_t passlen,
    const uint8_t *salt, size_t saltlen, uint8_t *key, size_t keylen,
    unsigned int rounds);
#endif
