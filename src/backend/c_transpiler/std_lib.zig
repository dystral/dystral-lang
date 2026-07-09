pub const std_lib_c = 
    \\#include <stdio.h>
    \\#include <stdlib.h>
    \\#include <gc.h>
    \\#include <string.h>
    \\#include <stdbool.h>
    \\
    \\#define assert(condition) if (!(condition)) { printf("[FAIL] Assertion failed: %s\n", #condition); exit(1); }
    \\
    \\typedef struct {
    \\    char* buffer;
    \\    int length;
    \\} AetherString;
    \\
    \\AetherString* AetherString_new(const char* literal) {
    \\    AetherString* s = (AetherString*)GC_MALLOC(sizeof(AetherString));
    \\    s->length = strlen(literal);
    \\    s->buffer = (char*)GC_MALLOC(s->length + 1);
    \\    strcpy(s->buffer, literal);
    \\    return s;
    \\}
    \\
    \\AetherString* AetherString_fromInt(int val) {
    \\    char buf[32];
    \\    sprintf(buf, "%d", val);
    \\    return AetherString_new(buf);
    \\}
    \\
    \\AetherString* AetherString_fromBool(bool val) {
    \\    return AetherString_new(val ? "true" : "false");
    \\}
    \\
    \\#define toString(x) _Generic((x), \
    \\    int: AetherString_fromInt((int)(size_t)(x)), \
    \\    AetherString*: (AetherString*)(size_t)(x), \
    \\    bool: AetherString_fromBool((bool)(size_t)(x)), \
    \\    default: AetherString_new("unknown") \
    \\)
    \\
    \\AetherString* _AetherString_plus(AetherString* a, AetherString* b) {
    \\    if (!a) a = AetherString_new("null");
    \\    if (!b) b = AetherString_new("null");
    \\    AetherString* s = (AetherString*)GC_MALLOC(sizeof(AetherString));
    \\    s->length = a->length + b->length;
    \\    s->buffer = (char*)GC_MALLOC(s->length + 1);
    \\    strcpy(s->buffer, a->buffer);
    \\    strcat(s->buffer, b->buffer);
    \\    return s;
    \\}
    \\
    \\#define AetherString_plus(a, b) _AetherString_plus(toString(a), toString(b))
    \\
    \\void AetherString_print(void* ptr) {
    \\    AetherString* s = (AetherString*)ptr;
    \\    if (s == NULL) printf("null\n");
    \\    else printf("%s\n", s->buffer);
    \\}
    \\
    \\#define print(x) _Generic((x), \
    \\    int: printf("%d\n", (int)(size_t)(x)), \
    \\    AetherString*: AetherString_print((void*)(size_t)(x)), \
    \\    bool: printf("%s\n", (x) ? "true" : "false"), \
    \\    default: printf("unknown\n") \
    \\)
    \\
;
