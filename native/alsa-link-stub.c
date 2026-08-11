#include "alsa-compat.h"

struct _snd_pcm {
    int unused;
};

const char *snd_strerror(int error) {
    (void)error;
    return "ALSA link stub";
}

int snd_lib_error_set_handler(snd_lib_error_handler_t handler) {
    (void)handler;
    return 0;
}

int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode) {
    (void)pcm;
    (void)name;
    (void)stream;
    (void)mode;
    return -1;
}

int snd_pcm_set_params(snd_pcm_t *pcm, snd_pcm_format_t format, snd_pcm_access_t access, unsigned int channels, unsigned int rate, int soft_resample, unsigned int latency) {
    (void)pcm;
    (void)format;
    (void)access;
    (void)channels;
    (void)rate;
    (void)soft_resample;
    (void)latency;
    return -1;
}

int snd_pcm_nonblock(snd_pcm_t *pcm, int nonblock) {
    (void)pcm;
    (void)nonblock;
    return -1;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size) {
    (void)pcm;
    (void)buffer;
    (void)size;
    return -1;
}

int snd_pcm_wait(snd_pcm_t *pcm, int timeout) {
    (void)pcm;
    (void)timeout;
    return -1;
}

int snd_pcm_prepare(snd_pcm_t *pcm) {
    (void)pcm;
    return -1;
}

int snd_pcm_resume(snd_pcm_t *pcm) {
    (void)pcm;
    return -1;
}

int snd_pcm_recover(snd_pcm_t *pcm, int error, int silent) {
    (void)pcm;
    (void)error;
    (void)silent;
    return -1;
}

int snd_pcm_drop(snd_pcm_t *pcm) {
    (void)pcm;
    return -1;
}

int snd_pcm_drain(snd_pcm_t *pcm) {
    (void)pcm;
    return -1;
}

int snd_pcm_close(snd_pcm_t *pcm) {
    (void)pcm;
    return 0;
}
