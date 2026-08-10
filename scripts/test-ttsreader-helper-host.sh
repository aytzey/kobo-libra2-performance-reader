#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="${HOST_CC:-cc}"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

if ! command -v "${CC}" >/dev/null 2>&1; then
  echo "skip: ${CC} not found"
  exit 0
fi

grep -q "SYS_ioprio_set" "${ROOT}/native/ttsreader-player.c"
grep -q "IOPRIO_CLASS_IDLE" "${ROOT}/native/ttsreader-player.c"

"${CC}" \
  -std=gnu99 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "${ROOT}/native/ttsreader-player.c" \
  -x c - \
  -o "${TMP}/helper-smoke" <<'C_EOF'
#include <stdio.h>
#include <unistd.h>

int ttsreader_player_spawn(const char *player_path, const char *audio_path, const char *device, double speed, double seek_seconds, double volume);
int ttsreader_player_spawn_control(const char *player_path, const char *audio_path, const char *device, double speed, double seek_seconds, double volume, const char *volume_control_path);
int ttsreader_player_reap(int pid);
int ttsreader_player_poll(int pid);

int main(void) {
    int pid = ttsreader_player_spawn("/bin/true", "/tmp/ttsreader-audio.mp3", "default", 1.2, 0.0, 0.8);
    if (pid <= 0) {
        fprintf(stderr, "spawn /bin/true failed: %d\n", pid);
        return 1;
    }

    int status = 0;
    for (int i = 0; i < 100; i++) {
        status = ttsreader_player_reap(pid);
        if (status == 1) {
            break;
        }
        usleep(10000);
    }
    if (status != 1) {
        fprintf(stderr, "spawned child was not reaped: %d\n", status);
        return 1;
    }

    int control_pid = ttsreader_player_spawn_control("/bin/true", "/tmp/ttsreader-audio.mp3", "default", 1.0, 0.0, 0.8, "/tmp/ttsreader-volume.ctl");
    if (control_pid <= 0) {
        fprintf(stderr, "spawn_control /bin/true failed: %d\n", control_pid);
        return 1;
    }
    for (int i = 0; i < 100; i++) {
        status = ttsreader_player_reap(control_pid);
        if (status == 1) {
            break;
        }
        usleep(10000);
    }
    if (status != 1) {
        fprintf(stderr, "spawn_control child was not reaped: %d\n", status);
        return 1;
    }

    int failed_pid = ttsreader_player_spawn("/bin/false", "/tmp/ttsreader-audio.mp3", "default", 1.0, 0.0, 1.5);
    if (failed_pid <= 0) {
        fprintf(stderr, "spawn /bin/false failed: %d\n", failed_pid);
        return 1;
    }
    int poll_status = 0;
    for (int i = 0; i < 100; i++) {
        poll_status = ttsreader_player_poll(failed_pid);
        if (poll_status != 0) {
            break;
        }
        usleep(10000);
    }
    if (poll_status >= 0) {
        fprintf(stderr, "failed child was not reported as an error: %d\n", poll_status);
        return 1;
    }

    int missing = ttsreader_player_spawn("/tmp/definitely-missing-ttsreader-play", "/tmp/ttsreader-audio.mp3", "default", 1.0, 0.0, 1.0);
    if (missing >= 0) {
        fprintf(stderr, "missing player unexpectedly spawned: %d\n", missing);
        return 1;
    }

    return 0;
}
C_EOF

"${TMP}/helper-smoke"
echo "ttsreader helper host smoke passed"
