#ifndef TTSREADER_ALSA_COMPAT_H
#define TTSREADER_ALSA_COMPAT_H

typedef struct _snd_pcm snd_pcm_t;
typedef long snd_pcm_sframes_t;

typedef enum {
    SND_PCM_STREAM_PLAYBACK = 0,
} snd_pcm_stream_t;

typedef enum {
    SND_PCM_ACCESS_RW_INTERLEAVED = 3,
} snd_pcm_access_t;

typedef enum {
    SND_PCM_FORMAT_S16_LE = 2,
} snd_pcm_format_t;

typedef void (*snd_lib_error_handler_t)(
    const char *file,
    int line,
    const char *function,
    int error,
    const char *format,
    ...
);

const char *snd_strerror(int error);
int snd_lib_error_set_handler(snd_lib_error_handler_t handler);
int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode);
int snd_pcm_set_params(
    snd_pcm_t *pcm,
    snd_pcm_format_t format,
    snd_pcm_access_t access,
    unsigned int channels,
    unsigned int rate,
    int soft_resample,
    unsigned int latency
);
int snd_pcm_nonblock(snd_pcm_t *pcm, int nonblock);
snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
int snd_pcm_wait(snd_pcm_t *pcm, int timeout);
int snd_pcm_prepare(snd_pcm_t *pcm);
int snd_pcm_resume(snd_pcm_t *pcm);
int snd_pcm_recover(snd_pcm_t *pcm, int error, int silent);
int snd_pcm_drop(snd_pcm_t *pcm);
int snd_pcm_drain(snd_pcm_t *pcm);
int snd_pcm_close(snd_pcm_t *pcm);

#endif
