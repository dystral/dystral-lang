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

#include <setjmp.h>

typedef struct AetherExceptionFrame {
    jmp_buf buf;
    struct AetherExceptionFrame* next;
} AetherExceptionFrame;

extern __thread AetherExceptionFrame* aether_exception_stack;
extern __thread void* aether_active_exception;

static inline void aether_push_exception_frame(AetherExceptionFrame* frame) {
    frame->next = aether_exception_stack;
    aether_exception_stack = frame;
}

static inline void aether_pop_exception_frame() {
    if (aether_exception_stack) {
        aether_exception_stack = aether_exception_stack->next;
    }
}

static inline void aether_throw(void* exception) {
    if (!aether_exception_stack) {
        const char* name = "UnknownException";
        if (exception) {
            const AetherClassDescriptor* desc = *(const AetherClassDescriptor**)exception;
            if (desc) name = desc->name;
        }
        fprintf(stderr, "Unhandled exception: %s occurred!\n", name);
        exit(1);
    }
    aether_active_exception = exception;
    longjmp(aether_exception_stack->buf, 1);
}

#endif // AETHER_RUNTIME_H
