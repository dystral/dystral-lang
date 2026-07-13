#ifndef AETHER_RUNTIME_H
#define AETHER_RUNTIME_H

#include <time.h>
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

static inline int aether_char_at(const char* str, int index) {
    return str[index];
}

static inline void aether_terminate(char *str, int index) {
    str[index] = '\0';
}

#endif // AETHER_RUNTIME_H
