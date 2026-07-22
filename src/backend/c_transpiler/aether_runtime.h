#ifndef AETHER_RUNTIME_H
#define AETHER_RUNTIME_H

#include <stdint.h>
#include <time.h>
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static inline int aether_char_at(const char* str, int index) {
    return str[index];
}

static inline void aether_terminate(char *str, int index) {
    str[index] = '\0';
}

typedef struct AetherContractDescriptor {
    const char* name;
} AetherContractDescriptor;

typedef struct AetherContractImpl {
    const AetherContractDescriptor* contract;
    void** vtable;
} AetherContractImpl;

typedef struct AetherTypeDescriptor {
    const char* name;
    const AetherContractImpl* impls;
    int impl_count;
} AetherTypeDescriptor;

extern const AetherTypeDescriptor core_Int_descriptor;
extern const AetherTypeDescriptor core_Bool_descriptor;
extern const AetherTypeDescriptor core_String_descriptor;

static inline bool aether_implements(const AetherTypeDescriptor* desc, const AetherContractDescriptor* target) {
    if (!desc || !target) return false;
    for (int i = 0; i < desc->impl_count; i++) {
        if (desc->impls[i].contract == target) return true;
    }
    return false;
}

static inline void** aether_find_vtable(const AetherTypeDescriptor* desc, const AetherContractDescriptor* target) {
    if (!desc || !target) return 0;
    for (int i = 0; i < desc->impl_count; i++) {
        if (desc->impls[i].contract == target) return desc->impls[i].vtable;
    }
    return 0;
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
            const AetherTypeDescriptor* desc = *(const AetherTypeDescriptor**)exception;
            if (desc) name = desc->name;
        }
        fprintf(stderr, "Unhandled exception: %s occurred!\n", name);
        exit(1);
    }
    aether_active_exception = exception;
    longjmp(aether_exception_stack->buf, 1);
}

// POSIX Net Helpers
static inline int aether_tcp_bind(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 10) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static inline int aether_tcp_accept(int fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    return accept(fd, (struct sockaddr*)&addr, &addr_len);
}

static inline int aether_socket_read(int fd, char* buf, int max_len) {
    return read(fd, buf, max_len);
}

static inline int aether_socket_write(int fd, const char* data, int len) {
    return write(fd, data, len);
}

static inline void aether_socket_close(int fd) {
    close(fd);
}

// Curl Helpers
#ifdef AETHER_USE_CURL
#include <curl/curl.h>

struct AetherCurlBuffer {
    char* data;
    size_t size;
};

static inline size_t aether_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t realsize = size * nmemb;
    struct AetherCurlBuffer* mem = (struct AetherCurlBuffer*)userp;
    char* ptr = GC_REALLOC(mem->data, mem->size + realsize + 1);
    if(!ptr) return 0;
    mem->data = ptr;
    memcpy(&(mem->data[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->data[mem->size] = 0;
    return realsize;
}

static inline void* aether_get_write_callback_ptr() {
    return (void*)aether_curl_write_callback;
}

static inline char* aether_curl_buf_data(void* buf) {
    return ((struct AetherCurlBuffer*)buf)->data;
}

static inline int aether_curl_buf_size(void* buf) {
    return (int)((struct AetherCurlBuffer*)buf)->size;
}

static inline int aether_curl_get_status(CURL* curl) {
    long response_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    return (int)response_code;
}

static inline int aether_curl_setopt_string(CURL* curl, CURLoption option, const void* value) {
    return curl_easy_setopt(curl, option, value);
}

static inline int aether_curl_setopt_ptr(CURL* curl, CURLoption option, void* value) {
    return curl_easy_setopt(curl, option, value);
}

static inline int aether_curl_setopt_int(CURL* curl, CURLoption option, int value) {
    return curl_easy_setopt(curl, option, (long)value);
}
#endif

typedef struct AetherClosure {
    void* fn_ptr;
    void* env;
    void* _pad;
} AetherClosure;

struct core_String;
typedef struct core_String core_String;
extern const AetherContractDescriptor core_Stringable_contract;
extern const AetherContractDescriptor core_Hashable_contract;
core_String* core_Bool_toString(bool val);
core_String* core_Int_toString(int val);
int core_Bool_hashCode(bool val);
int core_Int_hashCode(int val);

static inline core_String* aether_to_string(void* ptr) {
    if (!ptr) {
        typedef struct { const void* _desc; const char* ptr; int length; } Str;
        Str* s = (Str*)GC_MALLOC(sizeof(Str));
        s->_desc = NULL;
        s->ptr = "null";
        s->length = 4;
        return (core_String*)s;
    }
    uintptr_t val = (uintptr_t)ptr;
    if (val <= 1) return core_Bool_toString((bool)val);
    if (val < 0x10000) return core_Int_toString((int)val);
    const AetherTypeDescriptor* desc = *(const AetherTypeDescriptor**)ptr;
    if (desc == &core_String_descriptor) return (core_String*)ptr;
    return ((core_String*(*)(void*))aether_find_vtable(desc, &core_Stringable_contract)[0])(ptr);

}

static inline int aether_hash_code(void* ptr) {
    if (!ptr) return 0;
    uintptr_t val = (uintptr_t)ptr;
    if (val <= 1) return core_Bool_hashCode((bool)val);
    if (val < 0x10000) return core_Int_hashCode((int)val);
    return ((int(*)(void*))aether_find_vtable(*(const AetherTypeDescriptor**)ptr, &core_Hashable_contract)[0])(ptr);
}

#endif // AETHER_RUNTIME_H
