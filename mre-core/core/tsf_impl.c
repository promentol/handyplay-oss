/* Single-TU implementation of the vendored TinySoundFont headers
 * (../../vendor/TinySoundFont). The Zig side binds via hand-written externs in
 * core/tsf.zig; keep both in sync with the vendored pin (COMMIT_PIN). */
#define TSF_IMPLEMENTATION
#include "tsf.h"
#define TML_IMPLEMENTATION
#include "tml.h"
