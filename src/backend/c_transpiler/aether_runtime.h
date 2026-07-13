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

typedef struct AetherClassDescriptor {
    const char* name;
    const struct AetherClassDescriptor* super;
} AetherClassDescriptor;

static inline bool aether_is_instance(const AetherClassDescriptor* desc, const AetherClassDescriptor* target) {
    if (!desc || !target) return false;
    const AetherClassDescriptor* curr = desc;
    while (curr) {
        if (curr == target) return true;
        curr = curr->super;
    }
    return false;
}

#endif // AETHER_RUNTIME_H
