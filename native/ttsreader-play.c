#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _SVID_SOURCE
#define _XOPEN_SOURCE 700
#define MINIMP3_IMPLEMENTATION

#include "alsa-compat.h"
#include <errno.h>
#include <math.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define TTS_HAS_NEON 1
#else
#define TTS_HAS_NEON 0
#endif

#include "minimp3_ex.h"

#define IN_FRAMES_CAP 32768u
#define OUT_FRAMES_CAP 8192u
#define ALSA_DEFAULT_LATENCY_US 260000u
#define ALSA_BLUEALSA_LATENCY_US 420000u
#define ALSA_BLUEALSA_OPEN_RETRIES 8u
#define ALSA_REOPEN_RETRIES 10u
#define ALSA_RETRY_SLEEP_US 125000u
#define TTS_FRAC_BITS 16u
#define TTS_FRAC_ONE (1u << TTS_FRAC_BITS)
#define TTSREADER_PLAYBACK_NICE 18
#define TTS_VOLUME_BITS 12
#define TTS_VOLUME_ONE (1 << TTS_VOLUME_BITS)
#define TTS_VOLUME_MIN 0.2
#define TTS_VOLUME_MAX 1.5
#define TTS_VOLUME_POLL_CHUNKS 4u

#ifndef IOPRIO_WHO_PROCESS
#define IOPRIO_WHO_PROCESS 1
#endif
#ifndef IOPRIO_CLASS_IDLE
#define IOPRIO_CLASS_IDLE 3
#endif
#ifndef IOPRIO_PRIO_VALUE
#define IOPRIO_PRIO_VALUE(class_, data_) (((class_) << 13) | (data_))
#endif

#if defined(__GNUC__)
#define TTS_LIKELY(x) __builtin_expect(!!(x), 1)
#define TTS_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define TTS_LIKELY(x) (x)
#define TTS_UNLIKELY(x) (x)
#endif

static volatile sig_atomic_t keep_running = 1;
static const char *volume_control_path = NULL;
static int runtime_volume_q12 = TTS_VOLUME_ONE;
static time_t volume_control_mtime = 0;
static long volume_control_mtime_nsec = -1;
static off_t volume_control_size = -1;
static unsigned int volume_control_poll_count = 0;

typedef struct {
    snd_pcm_t *pcm;
    const char *device;
    unsigned int channels;
    unsigned int hz;
    unsigned int latency_us;
    unsigned int wait_timeout_ms;
    unsigned int drain_waits;
    unsigned int reopen_attempts;
    int quiet;
    int retry_transient;
} audio_output_t;

typedef struct {
    void *ctx;
    size_t (*read_samples)(void *ctx, int16_t *dst, size_t samples);
} pcm_source_t;

typedef struct {
    FILE *file;
    long data_offset;
    uint32_t data_size;
    uint32_t data_read;
    unsigned int channels;
    unsigned int hz;
    unsigned int block_align;
} wav_reader_t;

static inline void prefetch_read(const void *ptr) {
#if defined(__arm__)
    __asm__ __volatile__("pld [%0]" : : "r"(ptr));
#elif defined(__GNUC__)
    __builtin_prefetch(ptr, 0, 1);
#else
    (void)ptr;
#endif
}

static inline void cpu_relax(void) {
#if defined(__arm__) || defined(__aarch64__)
    __asm__ __volatile__("yield" ::: "memory");
#elif defined(__GNUC__)
    __asm__ __volatile__("" ::: "memory");
#endif
}

static void sleep_us_interruptible(unsigned int usec) {
    while (keep_running && usec > 0) {
        unsigned int chunk = usec > 20000u ? 20000u : usec;
        usleep(chunk);
        usec -= chunk;
        cpu_relax();
    }
}

static void handle_signal(int signo) {
    (void)signo;
    keep_running = 0;
}

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
}

static void lower_playback_priority(void) {
#ifdef SCHED_BATCH
    struct sched_param param;
    param.sched_priority = 0;
    (void)sched_setscheduler(0, SCHED_BATCH, &param);
#endif
#ifdef SYS_ioprio_set
    (void)syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, IOPRIO_PRIO_VALUE(IOPRIO_CLASS_IDLE, 0));
#endif
    (void)setpriority(PRIO_PROCESS, 0, TTSREADER_PLAYBACK_NICE);
}

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s [--device ALSA_PCM] [--speed RATE] [--volume GAIN] [--volume-control FILE] [--seek SECONDS] [--quiet] FILE\n",
        argv0);
}

static void quiet_alsa_error_handler(
    const char *file,
    int line,
    const char *function,
    int err,
    const char *fmt,
    ...) {
    (void)file;
    (void)line;
    (void)function;
    (void)err;
    (void)fmt;
}

static double clamp_speed(double speed) {
    if (speed < 0.5) {
        return 0.5;
    }
    if (speed > 2.0) {
        return 2.0;
    }
    return speed;
}

static double clamp_volume(double volume) {
    if (volume < TTS_VOLUME_MIN) {
        return TTS_VOLUME_MIN;
    }
    if (volume > TTS_VOLUME_MAX) {
        return TTS_VOLUME_MAX;
    }
    return volume;
}

static int volume_to_q12(double volume) {
    return (int)(clamp_volume(volume) * (double)TTS_VOLUME_ONE + 0.5);
}

static long stat_mtime_nsec(const struct stat *st) {
#if defined(__linux__)
    return st->st_mtim.tv_nsec;
#else
    (void)st;
    return 0;
#endif
}

static int refresh_volume_q12(int fallback_q12) {
    if (!volume_control_path || !*volume_control_path) {
        return fallback_q12;
    }
    if (runtime_volume_q12 > 0
        && volume_control_mtime_nsec >= 0
        && volume_control_poll_count++ < TTS_VOLUME_POLL_CHUNKS) {
        return runtime_volume_q12;
    }
    volume_control_poll_count = 0;

    struct stat st;
    if (stat(volume_control_path, &st) != 0) {
        return runtime_volume_q12 > 0 ? runtime_volume_q12 : fallback_q12;
    }

    long mtime_nsec = stat_mtime_nsec(&st);
    if (runtime_volume_q12 > 0
        && st.st_mtime == volume_control_mtime
        && mtime_nsec == volume_control_mtime_nsec
        && st.st_size == volume_control_size) {
        return runtime_volume_q12;
    }

    FILE *file = fopen(volume_control_path, "rb");
    if (!file) {
        return runtime_volume_q12 > 0 ? runtime_volume_q12 : fallback_q12;
    }

    char buf[64];
    if (fgets(buf, sizeof(buf), file)) {
        double value = atof(buf);
        if (value > 0.0) {
            runtime_volume_q12 = volume_to_q12(value);
        }
    }
    fclose(file);

    volume_control_mtime = st.st_mtime;
    volume_control_mtime_nsec = mtime_nsec;
    volume_control_size = st.st_size;
    return runtime_volume_q12 > 0 ? runtime_volume_q12 : fallback_q12;
}

static int has_ext(const char *path, const char *ext) {
    const char *dot = path ? strrchr(path, '.') : NULL;
    return dot && strcasecmp(dot, ext) == 0;
}

static int read_exact(FILE *file, void *dst, size_t size) {
    return fread(dst, 1, size, file) == size;
}

static uint16_t load_le16(const uint8_t bytes[2]) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t load_le32(const uint8_t bytes[4]) {
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

static int read_le16(FILE *file, uint16_t *value) {
    uint8_t bytes[2];
    if (!read_exact(file, bytes, sizeof(bytes))) {
        return 0;
    }
    *value = load_le16(bytes);
    return 1;
}

static int read_le32(FILE *file, uint32_t *value) {
    uint8_t bytes[4];
    if (!read_exact(file, bytes, sizeof(bytes))) {
        return 0;
    }
    *value = load_le32(bytes);
    return 1;
}

static void wav_reader_close(wav_reader_t *wav) {
    if (wav->file) {
        fclose(wav->file);
        wav->file = NULL;
    }
}

static int wav_reader_open(wav_reader_t *wav, const char *path) {
    memset(wav, 0, sizeof(*wav));
    FILE *file = fopen(path, "rb");
    if (!file) {
        return -1;
    }

    char riff[4];
    uint32_t riff_size;
    char wave[4];
    if (!read_exact(file, riff, sizeof(riff))
        || !read_le32(file, &riff_size)
        || !read_exact(file, wave, sizeof(wave))) {
        fclose(file);
        return 1;
    }
    (void)riff_size;
    if (memcmp(riff, "RIFF", 4) != 0 || memcmp(wave, "WAVE", 4) != 0) {
        fclose(file);
        return 1;
    }

    int have_fmt = 0;
    int have_data = 0;
    while (!have_data) {
        char chunk_id[4];
        uint32_t chunk_size;
        if (!read_exact(file, chunk_id, sizeof(chunk_id)) || !read_le32(file, &chunk_size)) {
            break;
        }
        long chunk_data = ftell(file);
        long next = chunk_data + (long)chunk_size + (long)(chunk_size & 1u);
        if (memcmp(chunk_id, "fmt ", 4) == 0) {
            uint16_t format;
            uint16_t channels;
            uint32_t hz;
            uint32_t byte_rate;
            uint16_t block_align;
            uint16_t bits_per_sample;
            if (chunk_size < 16
                || !read_le16(file, &format)
                || !read_le16(file, &channels)
                || !read_le32(file, &hz)
                || !read_le32(file, &byte_rate)
                || !read_le16(file, &block_align)
                || !read_le16(file, &bits_per_sample)) {
                fclose(file);
                return -1;
            }
            (void)byte_rate;
            if (format != 1 || bits_per_sample != 16 || channels < 1 || channels > 2 || hz == 0 || block_align != channels * 2u) {
                fclose(file);
                return -1;
            }
            wav->channels = channels;
            wav->hz = hz;
            wav->block_align = block_align;
            have_fmt = 1;
        } else if (memcmp(chunk_id, "data", 4) == 0) {
            if (!have_fmt) {
                fclose(file);
                return -1;
            }
            wav->data_offset = chunk_data;
            wav->data_size = chunk_size - (chunk_size % wav->block_align);
            have_data = wav->data_size > 0;
            break;
        }
        if (fseek(file, next, SEEK_SET) != 0) {
            fclose(file);
            return -1;
        }
    }

    if (!have_fmt || !have_data || fseek(file, wav->data_offset, SEEK_SET) != 0) {
        fclose(file);
        return -1;
    }
    wav->file = file;
    wav->data_read = 0;
    return 0;
}

static size_t wav_read_samples(void *ctx, int16_t *dst, size_t samples) {
    wav_reader_t *wav = (wav_reader_t *)ctx;
    if (!wav || !wav->file || wav->data_read >= wav->data_size) {
        return 0;
    }
    uint32_t remaining = wav->data_size - wav->data_read;
    size_t bytes = samples * sizeof(*dst);
    if (bytes > remaining) {
        bytes = remaining;
    }
    bytes -= bytes % wav->block_align;
    if (bytes == 0) {
        return 0;
    }
    size_t got = fread(dst, 1, bytes, wav->file);
    got -= got % wav->block_align;
    wav->data_read += (uint32_t)got;
    return got / sizeof(*dst);
}

static int wav_reader_seek(wav_reader_t *wav, double seconds) {
    if (!wav || !wav->file || seconds <= 0.0) {
        return 0;
    }
    uint64_t frame = (uint64_t)(seconds * (double)wav->hz);
    uint64_t byte_offset = frame * (uint64_t)wav->block_align;
    if (byte_offset > wav->data_size) {
        byte_offset = wav->data_size;
    }
    byte_offset -= byte_offset % wav->block_align;
    if (fseek(wav->file, wav->data_offset + (long)byte_offset, SEEK_SET) != 0) {
        return -1;
    }
    wav->data_read = (uint32_t)byte_offset;
    return 0;
}

static size_t mp3_read_samples(void *ctx, int16_t *dst, size_t samples) {
    return mp3dec_ex_read((mp3dec_ex_t *)ctx, dst, samples);
}

static inline int32_t mul_i32_q16(int32_t value, uint32_t frac_q16) {
#if defined(__arm__)
    int32_t lo;
    int32_t hi;
    __asm__ __volatile__(
        "smull %0, %1, %2, %3"
        : "=&r"(lo), "=&r"(hi)
        : "r"(value), "r"((int32_t)frac_q16));
    return (hi << TTS_FRAC_BITS) | (int32_t)((uint32_t)lo >> TTS_FRAC_BITS);
#else
    return (int32_t)(((int64_t)value * (int64_t)frac_q16) >> TTS_FRAC_BITS);
#endif
}

static inline int16_t lerp_i16_q16(int16_t a, int16_t b, uint32_t frac_q16) {
    int32_t sample = (int32_t)a + mul_i32_q16((int32_t)b - (int32_t)a, frac_q16);
    if (sample > 32767) {
        return 32767;
    }
    if (sample < -32768) {
        return -32768;
    }
    return (int16_t)sample;
}

static inline int16_t blend_i16_div2(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a + (int32_t)b) / 2);
}

static inline int16_t blend_i16_1_3_div4(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a + (int32_t)b * 3) / 4);
}

static inline int16_t blend_i16_3_1_div4(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a * 3 + (int32_t)b) / 4);
}

static inline int16_t blend_i16_4_1_div5(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a * 4 + (int32_t)b) / 5);
}

static inline int16_t blend_i16_3_2_div5(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a * 3 + (int32_t)b * 2) / 5);
}

static inline int16_t blend_i16_2_3_div5(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a * 2 + (int32_t)b * 3) / 5);
}

static inline int16_t blend_i16_1_4_div5(int16_t a, int16_t b) {
    return (int16_t)(((int32_t)a + (int32_t)b * 4) / 5);
}

static int is_bluealsa_device(const char *device) {
    return device && strstr(device, "bluealsa") != NULL;
}

static int is_reopenable_pcm_error(snd_pcm_sframes_t err) {
    int code = err < 0 ? -(int)err : (int)err;
    return code == EIO
        || code == ENODEV
        || code == ENOTCONN
        || code == EBADFD
        || code == ECONNRESET
        || code == ETIMEDOUT;
}

static void audio_output_close(audio_output_t *out) {
    if (out->pcm) {
        snd_pcm_close(out->pcm);
        out->pcm = NULL;
    }
}

static int audio_output_open(audio_output_t *out, unsigned int attempts) {
    if (attempts == 0) {
        attempts = 1;
    }

    int last_rc = -EINVAL;
    for (unsigned int attempt = 0; keep_running && attempt < attempts; attempt++) {
        snd_pcm_t *pcm = NULL;
        int rc = snd_pcm_open(&pcm, out->device, SND_PCM_STREAM_PLAYBACK, 0);
        if (rc >= 0) {
            rc = snd_pcm_set_params(
                pcm,
                SND_PCM_FORMAT_S16_LE,
                SND_PCM_ACCESS_RW_INTERLEAVED,
                out->channels,
                out->hz,
                1,
                out->latency_us);
            if (rc >= 0) {
                rc = snd_pcm_nonblock(pcm, 1);
            }
            if (rc >= 0) {
                out->pcm = pcm;
                return 0;
            }
            snd_pcm_close(pcm);
        }

        last_rc = rc;
        if (!out->retry_transient || attempt + 1u >= attempts) {
            break;
        }
        sleep_us_interruptible(ALSA_RETRY_SLEEP_US + attempt * 25000u);
    }

    if (!out->quiet && last_rc < 0) {
        fprintf(stderr, "ttsreader-play: ALSA open/setup failed for %s: %s\n", out->device, snd_strerror(last_rc));
    }
    return -1;
}

static int audio_output_reopen(audio_output_t *out) {
    if (!out->retry_transient || !keep_running) {
        return -1;
    }
    audio_output_close(out);
    sleep_us_interruptible(ALSA_RETRY_SLEEP_US);
    return audio_output_open(out, out->reopen_attempts);
}

static void audio_output_init(audio_output_t *out, const char *device, int channels, int hz, int quiet) {
    memset(out, 0, sizeof(*out));
    out->device = device && *device ? device : "default";
    out->channels = (unsigned int)channels;
    out->hz = (unsigned int)hz;
    out->quiet = quiet;
    out->retry_transient = is_bluealsa_device(out->device);
    out->latency_us = out->retry_transient ? ALSA_BLUEALSA_LATENCY_US : ALSA_DEFAULT_LATENCY_US;
    out->wait_timeout_ms = out->retry_transient ? 80u : 40u;
    out->drain_waits = out->retry_transient ? 12u : 20u;
    out->reopen_attempts = out->retry_transient ? ALSA_REOPEN_RETRIES : 1u;
}

static inline void copy_frame(int16_t *dst, const int16_t *src, int channels) {
    dst[0] = src[0];
    if (channels == 2) {
        dst[1] = src[1];
    }
}

static inline void copy_frame_stereo(int16_t *dst, const int16_t *src) {
    dst[0] = src[0];
    dst[1] = src[1];
}

static inline void blend_frame_mono_div2(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_div2(a[0], b[0]);
}

static inline void blend_frame_stereo_div2(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_div2(a[0], b[0]);
    dst[1] = blend_i16_div2(a[1], b[1]);
}

static inline void blend_frame_mono_1_3_div4(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_1_3_div4(a[0], b[0]);
}

static inline void blend_frame_stereo_1_3_div4(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_1_3_div4(a[0], b[0]);
    dst[1] = blend_i16_1_3_div4(a[1], b[1]);
}

static inline void blend_frame_mono_3_1_div4(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_3_1_div4(a[0], b[0]);
}

static inline void blend_frame_stereo_3_1_div4(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_3_1_div4(a[0], b[0]);
    dst[1] = blend_i16_3_1_div4(a[1], b[1]);
}

static inline void blend_frame_mono_4_1_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_4_1_div5(a[0], b[0]);
}

static inline void blend_frame_stereo_4_1_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_4_1_div5(a[0], b[0]);
    dst[1] = blend_i16_4_1_div5(a[1], b[1]);
}

static inline void blend_frame_mono_3_2_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_3_2_div5(a[0], b[0]);
}

static inline void blend_frame_stereo_3_2_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_3_2_div5(a[0], b[0]);
    dst[1] = blend_i16_3_2_div5(a[1], b[1]);
}

static inline void blend_frame_mono_2_3_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_2_3_div5(a[0], b[0]);
}

static inline void blend_frame_stereo_2_3_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_2_3_div5(a[0], b[0]);
    dst[1] = blend_i16_2_3_div5(a[1], b[1]);
}

static inline void blend_frame_mono_1_4_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_1_4_div5(a[0], b[0]);
}

static inline void blend_frame_stereo_1_4_div5(int16_t *dst, const int16_t *a, const int16_t *b) {
    dst[0] = blend_i16_1_4_div5(a[0], b[0]);
    dst[1] = blend_i16_1_4_div5(a[1], b[1]);
}

static inline int16_t scale_i16_q12(int16_t sample, int volume_q12) {
    int32_t scaled = (int32_t)sample * (int32_t)volume_q12;
    scaled += scaled >= 0 ? (TTS_VOLUME_ONE >> 1) : -(TTS_VOLUME_ONE >> 1);
    scaled >>= TTS_VOLUME_BITS;
    if (scaled > 32767) {
        return 32767;
    }
    if (scaled < -32768) {
        return -32768;
    }
    return (int16_t)scaled;
}

static void scale_samples_q12(int16_t *samples, size_t count, int volume_q12) {
    if (TTS_LIKELY(volume_q12 == TTS_VOLUME_ONE)) {
        return;
    }
#if TTS_HAS_NEON
    const int32x4_t positive_round = vdupq_n_s32(TTS_VOLUME_ONE >> 1);
    const int32x4_t negative_round = vdupq_n_s32(-(TTS_VOLUME_ONE >> 1));
    const int32x4_t zero = vdupq_n_s32(0);
    const int16_t volume = (int16_t)volume_q12;
    size_t i = 0;

    for (; i + 8u <= count; i += 8u) {
        if ((i & 127u) == 0 && i + 128u < count) {
            prefetch_read(samples + i + 128u);
        }
        int16x8_t src = vld1q_s16(samples + i);
        int16x4_t src_low = vget_low_s16(src);
        int16x4_t src_high = vget_high_s16(src);
        int32x4_t low = vmull_n_s16(src_low, volume);
        int32x4_t high = vmull_n_s16(src_high, volume);
        uint32x4_t low_negative = vcltq_s32(low, zero);
        uint32x4_t high_negative = vcltq_s32(high, zero);

        low = vaddq_s32(low, vbslq_s32(low_negative, negative_round, positive_round));
        high = vaddq_s32(high, vbslq_s32(high_negative, negative_round, positive_round));
        vst1q_s16(samples + i, vcombine_s16(vqmovn_s32(vshrq_n_s32(low, TTS_VOLUME_BITS)),
                                             vqmovn_s32(vshrq_n_s32(high, TTS_VOLUME_BITS))));
    }

    for (; i < count; i++) {
        samples[i] = scale_i16_q12(samples[i], volume_q12);
    }
#else
    for (size_t i = 0; i < count; i++) {
        if ((i & 63u) == 0 && i + 64u < count) {
            prefetch_read(samples + i + 64u);
        }
        samples[i] = scale_i16_q12(samples[i], volume_q12);
    }
#endif
}

static int write_pcm(audio_output_t *out, const int16_t *samples, size_t frames, int channels) {
    unsigned int idle_writes = 0;
    unsigned int xrun_recoveries = 0;
    while (frames > 0 && keep_running) {
        if (!out->pcm && audio_output_reopen(out) != 0) {
            return -1;
        }

        snd_pcm_sframes_t written = snd_pcm_writei(out->pcm, samples, frames);
        if (written > 0) {
            idle_writes = 0;
            xrun_recoveries = 0;
            samples += written * channels;
            frames -= (size_t)written;
            continue;
        }
        if (written == 0 || written == -EAGAIN) {
            if (++idle_writes > 1000u) {
                return -1;
            }
            int waited = snd_pcm_wait(out->pcm, (int)out->wait_timeout_ms);
            if (waited < 0 && out->retry_transient && is_reopenable_pcm_error(waited)) {
                if (audio_output_reopen(out) == 0) {
                    idle_writes = 0;
                    continue;
                }
                return -1;
            }
            if (waited <= 0) {
                sleep_us_interruptible(1000u);
            }
            continue;
        }
        if (written == -EPIPE) {
            int prepared = snd_pcm_prepare(out->pcm);
            if (prepared < 0 || (out->retry_transient && ++xrun_recoveries > 3u)) {
                if (out->retry_transient && audio_output_reopen(out) == 0) {
                    xrun_recoveries = 0;
                    continue;
                }
                return -1;
            }
            continue;
        }
        if (written == -ESTRPIPE) {
            while (keep_running && (written = snd_pcm_resume(out->pcm)) == -EAGAIN) {
                sleep_us_interruptible(1000u);
            }
            if (written < 0) {
                snd_pcm_prepare(out->pcm);
            }
            continue;
        }
        if (written < 0) {
            snd_pcm_sframes_t recovered = snd_pcm_recover(out->pcm, (int)written, 0);
            if (recovered < 0 && out->retry_transient && (is_reopenable_pcm_error(written) || is_reopenable_pcm_error(recovered))) {
                if (audio_output_reopen(out) == 0) {
                    continue;
                }
            }
            if (recovered < 0) {
                if (!out->quiet) {
                    fprintf(stderr, "ttsreader-play: ALSA write failed on %s: %s\n", out->device, snd_strerror((int)recovered));
                }
                return -1;
            }
            continue;
        }
    }
    return 0;
}

static void audio_output_finish(audio_output_t *out, int result) {
    if (!out->pcm) {
        return;
    }
    if (!keep_running || result != 0) {
        snd_pcm_drop(out->pcm);
        return;
    }

    for (unsigned int i = 0; keep_running && i < out->drain_waits; i++) {
        int rc = snd_pcm_drain(out->pcm);
        if (rc == 0) {
            return;
        }
        if (rc == -EAGAIN) {
            int waited = snd_pcm_wait(out->pcm, (int)out->wait_timeout_ms);
            if (waited < 0 && out->retry_transient && is_reopenable_pcm_error(waited)) {
                break;
            }
            if (waited <= 0) {
                sleep_us_interruptible(1000u);
            }
            continue;
        }
        if (out->retry_transient && is_reopenable_pcm_error(rc)) {
            break;
        }
        if (snd_pcm_recover(out->pcm, rc, 0) < 0) {
            break;
        }
    }

    snd_pcm_drop(out->pcm);
}

static int write_pcm_scaled(audio_output_t *out, int16_t *samples, size_t frames, int channels, int volume_q12) {
    if (frames == 0) {
        return 0;
    }
    scale_samples_q12(samples, frames * (size_t)channels, refresh_volume_q12(volume_q12));
    return write_pcm(out, samples, frames, channels);
}

static int flush_tail_pcm(audio_output_t *out, int16_t *samples, size_t frames, int channels, int volume_q12) {
    if (frames == 0) {
        return 0;
    }
    return write_pcm_scaled(out, samples, frames, channels, volume_q12);
}

static int play_0_75x_pattern(pcm_source_t *src, audio_output_t *outdev, int channels, int volume_q12) {
    const size_t read_frames_cap = (OUT_FRAMES_CAP / 4u) * 3u;
    const size_t in_frames_cap = read_frames_cap + 3u;
    const size_t in_samples_cap = in_frames_cap * (size_t)channels;
    const size_t out_samples_cap = OUT_FRAMES_CAP * (size_t)channels;
    int16_t *in = malloc(in_samples_cap * sizeof(*in));
    int16_t *out = malloc(out_samples_cap * sizeof(*out));
    size_t pending_frames = 0;

    if (!in || !out) {
        free(in);
        free(out);
        return -1;
    }

    while (keep_running) {
        size_t got = src->read_samples(
            src->ctx,
            in + pending_frames * (size_t)channels,
            read_frames_cap * (size_t)channels);
        size_t frames = pending_frames + got / (size_t)channels;
        if (frames < 4) {
            if (got == 0) {
                int rc = flush_tail_pcm(outdev, in, frames, channels, volume_q12);
                free(in);
                free(out);
                return rc;
            }
            pending_frames = frames;
            continue;
        }

        size_t groups = (frames - 1u) / 3u;
        size_t usable_frames = groups * 3u;
        size_t out_frames = 0;
        if (channels == 2) {
            for (size_t frame = 0; frame < usable_frames; frame += 3u) {
                const int16_t *a = in + frame * 2u;
                const int16_t *b = a + 2u;
                const int16_t *c = b + 2u;
                const int16_t *d = c + 2u;
                int16_t *dst = out + out_frames * 2u;
                copy_frame_stereo(dst, a);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_1_3_div4(dst, a, b);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_div2(dst, b, c);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_3_1_div4(dst, c, d);
                out_frames++;
            }
        } else {
            for (size_t frame = 0; frame < usable_frames; frame += 3u) {
                const int16_t *a = in + frame;
                const int16_t *b = a + 1u;
                const int16_t *c = b + 1u;
                const int16_t *d = c + 1u;
                int16_t *dst = out + out_frames;
                dst[0] = a[0];
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_1_3_div4(dst, a, b);
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_div2(dst, b, c);
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_3_1_div4(dst, c, d);
                out_frames++;
            }
        }

        if (out_frames > 0 && write_pcm_scaled(outdev, out, out_frames, channels, volume_q12) != 0) {
            free(in);
            free(out);
            return -1;
        }

        pending_frames = frames - usable_frames;
        if (pending_frames > 0) {
            memmove(in, in + usable_frames * (size_t)channels, pending_frames * (size_t)channels * sizeof(*in));
        }
        if (got == 0) {
            if (flush_tail_pcm(outdev, in, pending_frames, channels, volume_q12) != 0) {
                free(in);
                free(out);
                return -1;
            }
            break;
        }
    }

    free(in);
    free(out);
    return 0;
}

static int play_1_2x_pattern(pcm_source_t *src, audio_output_t *outdev, int channels, int volume_q12) {
    const size_t groups_cap = OUT_FRAMES_CAP / 5u;
    const size_t read_frames_cap = groups_cap * 6u;
    const size_t in_frames_cap = read_frames_cap + 5u;
    const size_t in_samples_cap = in_frames_cap * (size_t)channels;
    const size_t out_samples_cap = OUT_FRAMES_CAP * (size_t)channels;
    int16_t *in = malloc(in_samples_cap * sizeof(*in));
    int16_t *out = malloc(out_samples_cap * sizeof(*out));
    size_t pending_frames = 0;

    if (!in || !out) {
        free(in);
        free(out);
        return -1;
    }

    while (keep_running) {
        size_t got = src->read_samples(
            src->ctx,
            in + pending_frames * (size_t)channels,
            read_frames_cap * (size_t)channels);
        size_t frames = pending_frames + got / (size_t)channels;
        if (frames < 6) {
            if (got == 0) {
                int rc = flush_tail_pcm(outdev, in, frames, channels, volume_q12);
                free(in);
                free(out);
                return rc;
            }
            pending_frames = frames;
            continue;
        }

        size_t usable_frames = (frames / 6u) * 6u;
        size_t out_frames = 0;
        if (channels == 2) {
            for (size_t frame = 0; frame < usable_frames; frame += 6u) {
                const int16_t *a = in + frame * 2u;
                const int16_t *b = a + 2u;
                const int16_t *c = b + 2u;
                const int16_t *d = c + 2u;
                const int16_t *e = d + 2u;
                const int16_t *f = e + 2u;
                int16_t *dst = out + out_frames * 2u;
                copy_frame_stereo(dst, a);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_4_1_div5(dst, b, c);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_3_2_div5(dst, c, d);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_2_3_div5(dst, d, e);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_1_4_div5(dst, e, f);
                out_frames++;
            }
        } else {
            for (size_t frame = 0; frame < usable_frames; frame += 6u) {
                const int16_t *a = in + frame;
                const int16_t *b = a + 1u;
                const int16_t *c = b + 1u;
                const int16_t *d = c + 1u;
                const int16_t *e = d + 1u;
                const int16_t *f = e + 1u;
                int16_t *dst = out + out_frames;
                dst[0] = a[0];
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_4_1_div5(dst, b, c);
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_3_2_div5(dst, c, d);
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_2_3_div5(dst, d, e);
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_1_4_div5(dst, e, f);
                out_frames++;
            }
        }

        if (out_frames > 0 && write_pcm_scaled(outdev, out, out_frames, channels, volume_q12) != 0) {
            free(in);
            free(out);
            return -1;
        }

        pending_frames = frames - usable_frames;
        if (pending_frames > 0) {
            memmove(in, in + usable_frames * (size_t)channels, pending_frames * (size_t)channels * sizeof(*in));
        }
        if (got == 0) {
            if (flush_tail_pcm(outdev, in, pending_frames, channels, volume_q12) != 0) {
                free(in);
                free(out);
                return -1;
            }
            break;
        }
    }

    free(in);
    free(out);
    return 0;
}

static int play_1_5x_pattern(pcm_source_t *src, audio_output_t *outdev, int channels, int volume_q12) {
    const size_t read_frames_cap = (OUT_FRAMES_CAP * 3u) / 2u;
    const size_t in_frames_cap = read_frames_cap + 2u;
    const size_t in_samples_cap = in_frames_cap * (size_t)channels;
    const size_t out_samples_cap = OUT_FRAMES_CAP * (size_t)channels;
    int16_t *in = malloc(in_samples_cap * sizeof(*in));
    int16_t *out = malloc(out_samples_cap * sizeof(*out));
    size_t pending_frames = 0;

    if (!in || !out) {
        free(in);
        free(out);
        return -1;
    }

    while (keep_running) {
        size_t got = src->read_samples(
            src->ctx,
            in + pending_frames * (size_t)channels,
            read_frames_cap * (size_t)channels);
        size_t frames = pending_frames + got / (size_t)channels;
        if (frames < 3) {
            if (got == 0) {
                int rc = flush_tail_pcm(outdev, in, frames, channels, volume_q12);
                free(in);
                free(out);
                return rc;
            }
            pending_frames = frames;
            continue;
        }

        size_t usable_frames = (frames / 3u) * 3u;
        size_t out_frames = 0;
        if (channels == 2) {
            for (size_t frame = 0; frame < usable_frames; frame += 3u) {
                const int16_t *a = in + frame * 2u;
                const int16_t *b = a + 2u;
                const int16_t *c = b + 2u;
                int16_t *dst = out + out_frames * 2u;
                copy_frame_stereo(dst, a);
                out_frames++;

                dst = out + out_frames * 2u;
                blend_frame_stereo_div2(dst, b, c);
                out_frames++;
            }
        } else {
            for (size_t frame = 0; frame < usable_frames; frame += 3u) {
                const int16_t *a = in + frame;
                const int16_t *b = a + 1u;
                const int16_t *c = b + 1u;
                int16_t *dst = out + out_frames;
                dst[0] = a[0];
                out_frames++;

                dst = out + out_frames;
                blend_frame_mono_div2(dst, b, c);
                out_frames++;
            }
        }

        if (out_frames > 0 && write_pcm_scaled(outdev, out, out_frames, channels, volume_q12) != 0) {
            free(in);
            free(out);
            return -1;
        }

        pending_frames = frames - usable_frames;
        if (pending_frames > 0) {
            memmove(in, in + usable_frames * (size_t)channels, pending_frames * (size_t)channels * sizeof(*in));
        }
        if (got == 0) {
            if (flush_tail_pcm(outdev, in, pending_frames, channels, volume_q12) != 0) {
                free(in);
                free(out);
                return -1;
            }
            break;
        }
    }

    free(in);
    free(out);
    return 0;
}

static int play_resampled(pcm_source_t *src, audio_output_t *outdev, int channels, double speed, int volume_q12) {
    const size_t in_samples_cap = IN_FRAMES_CAP * (size_t)channels;
    const size_t out_samples_cap = OUT_FRAMES_CAP * (size_t)channels;
    int16_t *in = malloc(in_samples_cap * sizeof(*in));
    int16_t *out = malloc(out_samples_cap * sizeof(*out));
    size_t in_frames = 0;
    uint64_t pos_q16 = 0;
    uint32_t step_q16 = (uint32_t)(speed * (double)TTS_FRAC_ONE + 0.5);
    int eof = 0;

    if (!in || !out) {
        free(in);
        free(out);
        return -1;
    }
    if (step_q16 == 0) {
        step_q16 = TTS_FRAC_ONE;
    }

    while (keep_running) {
        if (!eof && in_frames < IN_FRAMES_CAP / 2) {
            size_t free_samples = in_samples_cap - in_frames * (size_t)channels;
            size_t got = src->read_samples(src->ctx, in + in_frames * (size_t)channels, free_samples);
            if (got == 0) {
                eof = 1;
            } else {
                in_frames += got / (size_t)channels;
            }
        }

        if (in_frames < 2) {
            break;
        }

        size_t out_frames = 0;
        while (out_frames < OUT_FRAMES_CAP) {
            size_t base = (size_t)(pos_q16 >> TTS_FRAC_BITS);
            if (base + 1u >= in_frames) {
                break;
            }
            uint32_t frac_q16 = (uint32_t)(pos_q16 & (TTS_FRAC_ONE - 1u));
            size_t prefetch_frame = base + 8u;
            if (prefetch_frame < in_frames) {
                prefetch_read(in + prefetch_frame * (size_t)channels);
            }
            size_t out_idx = out_frames * (size_t)channels;
            size_t base_idx = base * (size_t)channels;
            if (channels == 2) {
                out[out_idx] = lerp_i16_q16(
                    in[base_idx],
                    in[base_idx + 2u],
                    frac_q16);
                out[out_idx + 1u] = lerp_i16_q16(
                    in[base_idx + 1u],
                    in[base_idx + 3u],
                    frac_q16);
            } else {
                out[out_idx] = lerp_i16_q16(
                    in[base_idx],
                    in[base_idx + 1u],
                    frac_q16);
            }
            out_frames++;
            pos_q16 += step_q16;
        }

        if (out_frames > 0 && write_pcm_scaled(outdev, out, out_frames, channels, volume_q12) != 0) {
            free(in);
            free(out);
            return -1;
        }

        size_t consumed = (size_t)(pos_q16 >> TTS_FRAC_BITS);
        if (consumed > 0) {
            size_t remain_frames = in_frames - consumed;
            memmove(in, in + consumed * (size_t)channels, remain_frames * (size_t)channels * sizeof(*in));
            in_frames = remain_frames;
            pos_q16 -= (uint64_t)consumed << TTS_FRAC_BITS;
        }

        if (eof && (size_t)(pos_q16 >> TTS_FRAC_BITS) + 1u >= in_frames) {
            break;
        }
    }

    free(in);
    free(out);
    return 0;
}

static int play_2x_decimated(pcm_source_t *src, audio_output_t *outdev, int channels, int volume_q12) {
    const size_t in_samples_cap = OUT_FRAMES_CAP * 2u * (size_t)channels;
    const size_t out_samples_cap = OUT_FRAMES_CAP * (size_t)channels;
    int16_t *in = malloc(in_samples_cap * sizeof(*in));
    int16_t *out = malloc(out_samples_cap * sizeof(*out));
    int should_copy_frame = 1;

    if (!in || !out) {
        free(in);
        free(out);
        return -1;
    }

    while (keep_running) {
        size_t got = src->read_samples(src->ctx, in, in_samples_cap);
        if (got == 0) {
            break;
        }
        size_t frames = got / (size_t)channels;
        size_t out_frames = 0;
        size_t frame = should_copy_frame ? 0u : 1u;
        if (channels == 2) {
            for (; frame < frames; frame += 2u) {
                copy_frame_stereo(out + out_frames * 2u, in + frame * 2u);
                out_frames++;
            }
        } else {
            for (; frame < frames; frame += 2u) {
                out[out_frames++] = in[frame];
            }
        }
        if ((frames & 1u) != 0) {
            should_copy_frame = !should_copy_frame;
        }
        if (out_frames > 0 && write_pcm_scaled(outdev, out, out_frames, channels, volume_q12) != 0) {
            free(in);
            free(out);
            return -1;
        }
    }

    free(in);
    free(out);
    return 0;
}

static int play_pcm_source(pcm_source_t *src, audio_output_t *outdev, int channels, double speed, int volume_q12) {
    if (speed > 0.999 && speed < 1.001) {
        size_t samples_cap = OUT_FRAMES_CAP * (size_t)channels;
        int16_t *samples = malloc(samples_cap * sizeof(*samples));
        if (!samples) {
            return -1;
        }
        int result = 0;
        while (keep_running) {
            size_t got = src->read_samples(src->ctx, samples, samples_cap);
            if (got == 0) {
                break;
            }
            if (write_pcm_scaled(outdev, samples, got / (size_t)channels, channels, volume_q12) != 0) {
                result = -1;
                break;
            }
        }
        free(samples);
        return result;
    }
    if (speed > 1.999 && speed < 2.001) {
        return play_2x_decimated(src, outdev, channels, volume_q12);
    }
    if (speed > 1.499 && speed < 1.501) {
        return play_1_5x_pattern(src, outdev, channels, volume_q12);
    }
    if (speed > 1.199 && speed < 1.201) {
        return play_1_2x_pattern(src, outdev, channels, volume_q12);
    }
    if (speed > 0.749 && speed < 0.751) {
        return play_0_75x_pattern(src, outdev, channels, volume_q12);
    }
    return play_resampled(src, outdev, channels, speed, volume_q12);
}

int main(int argc, char **argv) {
    const char *device = "default";
    const char *path = NULL;
    double speed = 1.0;
    double volume = 1.0;
    double seek_seconds = 0.0;
    int quiet = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            device = argv[++i];
        } else if (strcmp(argv[i], "--speed") == 0 && i + 1 < argc) {
            speed = atof(argv[++i]);
        } else if (strcmp(argv[i], "--volume") == 0 && i + 1 < argc) {
            volume = atof(argv[++i]);
        } else if (strcmp(argv[i], "--volume-control") == 0 && i + 1 < argc) {
            volume_control_path = argv[++i];
        } else if (strcmp(argv[i], "--seek") == 0 && i + 1 < argc) {
            seek_seconds = atof(argv[++i]);
        } else if (strcmp(argv[i], "--quiet") == 0) {
            quiet = 1;
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (!path) {
            path = argv[i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (!path) {
        usage(argv[0]);
        return 2;
    }

    if (quiet) {
        snd_lib_error_set_handler(quiet_alsa_error_handler);
    }

    lower_playback_priority();
    speed = clamp_speed(speed);
    volume = clamp_volume(volume);
    const int volume_q12 = volume_to_q12(volume);
    runtime_volume_q12 = volume_q12;
    if (volume_control_path && *volume_control_path) {
        runtime_volume_q12 = refresh_volume_q12(volume_q12);
    }
    if (seek_seconds < 0.0) {
        seek_seconds = 0.0;
    }

    install_signal_handlers();

    wav_reader_t wav;
    int wav_status = wav_reader_open(&wav, path);
    if (wav_status == 0) {
        if (wav_reader_seek(&wav, seek_seconds) != 0) {
            wav_reader_close(&wav);
            return 1;
        }
        audio_output_t outdev;
        audio_output_init(&outdev, device, (int)wav.channels, (int)wav.hz, quiet);
        if (audio_output_open(&outdev, outdev.retry_transient ? ALSA_BLUEALSA_OPEN_RETRIES : 1u) != 0) {
            wav_reader_close(&wav);
            return 1;
        }
        pcm_source_t source = {
            .ctx = &wav,
            .read_samples = wav_read_samples,
        };
        int result = play_pcm_source(&source, &outdev, (int)wav.channels, speed, volume_q12);
        audio_output_finish(&outdev, result);
        audio_output_close(&outdev);
        wav_reader_close(&wav);
        return result == 0 ? 0 : 1;
    }
    if (wav_status < 0 && has_ext(path, ".wav")) {
        if (!quiet) {
            fprintf(stderr, "ttsreader-play: unsupported WAV/PCM file: %s\n", path);
        }
        return 1;
    }

    mp3dec_ex_t dec;
    memset(&dec, 0, sizeof(dec));
    int open_result = mp3dec_ex_open(&dec, path, MP3D_SEEK_TO_SAMPLE | MP3D_DO_NOT_SCAN);
    if (open_result != 0) {
        if (!quiet) {
            fprintf(stderr, "ttsreader-play: could not open MP3: %s (%d)\n", path, open_result);
        }
        return 1;
    }

    int channels = dec.info.channels > 0 ? dec.info.channels : 2;
    int hz = dec.info.hz > 0 ? dec.info.hz : 44100;
    if (channels > 2) {
        channels = 2;
    }

    if (seek_seconds > 0.0) {
        uint64_t seek_sample = (uint64_t)(seek_seconds * (double)hz * (double)channels);
        mp3dec_ex_seek(&dec, seek_sample);
    }

    audio_output_t outdev;
    audio_output_init(&outdev, device, channels, hz, quiet);
    if (audio_output_open(&outdev, outdev.retry_transient ? ALSA_BLUEALSA_OPEN_RETRIES : 1u) != 0) {
        mp3dec_ex_close(&dec);
        return 1;
    }

    pcm_source_t source = {
        .ctx = &dec,
        .read_samples = mp3_read_samples,
    };
    int result = play_pcm_source(&source, &outdev, channels, speed, volume_q12);

    audio_output_finish(&outdev, result);
    audio_output_close(&outdev);
    mp3dec_ex_close(&dec);
    return result == 0 ? 0 : 1;
}
