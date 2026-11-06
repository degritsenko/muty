#ifndef MUTY_SECURECRT_INCLUDES_H
#define MUTY_SECURECRT_INCLUDES_H
#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define HAVE_STDLIB_H 1
#define HAVE_BLF_H 1
#define bcrypt_pbkdf muty_securecrt_bcrypt_pbkdf
static inline void muty_explicit_bzero(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}
static inline void muty_freezero(void *p, size_t n) {
    if (p) { muty_explicit_bzero(p, n); free(p); }
}
#define explicit_bzero muty_explicit_bzero
#define freezero muty_freezero
#endif
