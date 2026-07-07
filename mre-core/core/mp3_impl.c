/* Single-TU implementation of the vendored minimp3 (../../vendor/minimp3)
 * plus a flat decode-whole-clip shim so the Zig side (core/audio.zig) needs no
 * C struct layouts. MRE clips are small (tens of KB of MP3 -> a few MB PCM),
 * so decode-on-open into one buffer keeps the engine's mixer trivial. */
#define MINIMP3_IMPLEMENTATION
#include "minimp3_ex.h"
#include <stdlib.h>

/* Decode an entire MP3 clip to interleaved s16 PCM. On success returns 0 and
 * hands over a malloc'd buffer (free() / Zig c_allocator compatible).
 * out_samples counts individual samples (channels included). */
int mre_mp3_decode(const unsigned char *buf, size_t len,
                   short **out_pcm, size_t *out_samples,
                   int *out_channels, int *out_hz)
{
    mp3dec_t dec;
    mp3dec_file_info_t info;
    if (mp3dec_load_buf(&dec, buf, len, &info, NULL, NULL))
        return -1;
    if (!info.buffer || !info.samples || info.channels < 1 || info.hz < 1) {
        free(info.buffer);
        return -1;
    }
    *out_pcm = info.buffer;
    *out_samples = info.samples;
    *out_channels = info.channels;
    *out_hz = info.hz;
    return 0;
}
