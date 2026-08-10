#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="${HOST_CC:-cc}"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "skip: $1 not found"
    exit 0
  fi
}

need_command "${CC}"
need_command ffmpeg

grep -q "snd_pcm_nonblock" "${ROOT}/native/ttsreader-play.c"
grep -q "audio_output_finish" "${ROOT}/native/ttsreader-play.c"
grep -q "snd_lib_error_set_handler" "${ROOT}/native/ttsreader-play.c"
grep -q "ALSA_BLUEALSA_OPEN_RETRIES 8u" "${ROOT}/native/ttsreader-play.c"
grep -q -- "--volume-control" "${ROOT}/native/ttsreader-play.c"
grep -q "TTS_HAS_NEON" "${ROOT}/native/ttsreader-play.c"
grep -q "vld1q_s16" "${ROOT}/native/ttsreader-play.c"
grep -q "TTS_VOLUME_POLL_CHUNKS" "${ROOT}/native/ttsreader-play.c"
grep -q "volume_control_poll_count" "${ROOT}/native/ttsreader-play.c"
grep -q "SYS_ioprio_set" "${ROOT}/native/ttsreader-play.c"
grep -q "IOPRIO_CLASS_IDLE" "${ROOT}/native/ttsreader-play.c"
grep -q "blend_frame_stereo_4_1_div5" "${ROOT}/native/ttsreader-play.c"
grep -q "blend_frame_mono_1_3_div4" "${ROOT}/native/ttsreader-play.c"
! grep -q "static inline void blend_frame(" "${ROOT}/native/ttsreader-play.c"
grep -q "if not self.ui or not self.ui.document then" "${ROOT}/koreader-src/frontend/apps/reader/modules/readerrolling.lua"

MP3_LONG="${TMP}/tone.mp3"
MP3_SHORT="${TMP}/tick.mp3"
WAV_LONG="${TMP}/tone.wav"
WAV_SHORT="${TMP}/tick.wav"
PLAYER="${TMP}/ttsreader-play-host"
VOLUME_CTL="${TMP}/volume.ctl"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i sine=frequency=440:duration=1.2 \
  -ar 44100 \
  -ac 2 \
  -codec:a libmp3lame \
  -q:a 6 \
  "${MP3_LONG}"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i sine=frequency=440:duration=1.2 \
  -ar 22050 \
  -ac 1 \
  -codec:a pcm_s16le \
  "${WAV_LONG}"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i sine=frequency=880:duration=0.02 \
  -ar 44100 \
  -ac 2 \
  -codec:a libmp3lame \
  -q:a 6 \
  "${MP3_SHORT}"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i sine=frequency=880:duration=0.02 \
  -ar 22050 \
  -ac 1 \
  -codec:a pcm_s16le \
  "${WAV_SHORT}"

"${CC}" \
  -std=gnu99 \
  -O3 \
  -DNDEBUG \
  -Wall \
  -Wextra \
  -Wno-cpp \
  -I"${ROOT}/third_party/minimp3" \
  "${ROOT}/native/ttsreader-play.c" \
  -lasound \
  -lm \
  -o "${PLAYER}"

printf '0.65\n' >"${VOLUME_CTL}"

for audio in "${MP3_LONG}" "${MP3_SHORT}" "${WAV_LONG}" "${WAV_SHORT}"; do
  for speed in 0.75 1.0 1.2 1.5 2.0; do
    for volume in 0.5 1.0 1.5; do
      "${PLAYER}" --quiet --device null --speed "${speed}" --volume "${volume}" "${audio}"
      "${PLAYER}" --quiet --device null --speed "${speed}" --volume "${volume}" --volume-control "${VOLUME_CTL}" "${audio}"
    done
  done
done

echo "ttsreader player host smoke passed"
