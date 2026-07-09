#ifndef AETHER_RUNTIME_H
#define AETHER_RUNTIME_H

#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define assert(condition) if (!(condition)) { printf("[FAIL] Assertion failed: %s\n", #condition); exit(1); }

#endif // AETHER_RUNTIME_H
