#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <sched.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define TTSREADER_MAX_INHERITED_FD 64
#define TTSREADER_ARMHF_LOADER "/lib/ld-linux-armhf.so.3"
#define TTSREADER_PLAYBACK_NICE 18

#ifndef IOPRIO_WHO_PROCESS
#define IOPRIO_WHO_PROCESS 1
#endif
#ifndef IOPRIO_CLASS_IDLE
#define IOPRIO_CLASS_IDLE 3
#endif
#ifndef IOPRIO_PRIO_VALUE
#define IOPRIO_PRIO_VALUE(class_, data_) (((class_) << 13) | (data_))
#endif

extern char **environ;

static inline void ttsreader_signal_barrier(void) {
#if defined(__arm__) || defined(__aarch64__)
    __asm__ __volatile__("dmb ish" ::: "memory");
#else
    __asm__ __volatile__("" ::: "memory");
#endif
}

static void ttsreader_lower_child_priority(pid_t pid) {
#ifdef SCHED_BATCH
    struct sched_param param;
    param.sched_priority = 0;
    (void)sched_setscheduler(pid, SCHED_BATCH, &param);
#endif
#ifdef SYS_ioprio_set
    (void)syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, (int)pid, IOPRIO_PRIO_VALUE(IOPRIO_CLASS_IDLE, 0));
#endif
    (void)setpriority(PRIO_PROCESS, (id_t)pid, TTSREADER_PLAYBACK_NICE);
}

static int ttsreader_add_devnull(posix_spawn_file_actions_t *actions, int fd, int flags) {
    int rc = posix_spawn_file_actions_addopen(actions, fd, "/dev/null", flags, 0);
    return rc == 0 ? 0 : -rc;
}

static int ttsreader_spawn_path(const char *path, char *const argv[], pid_t *pid) {
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) {
        return -rc;
    }

    int result = ttsreader_add_devnull(&actions, STDIN_FILENO, O_RDONLY);
    if (result == 0) {
        result = ttsreader_add_devnull(&actions, STDOUT_FILENO, O_WRONLY);
    }
    if (result == 0) {
        result = ttsreader_add_devnull(&actions, STDERR_FILENO, O_WRONLY);
    }
    for (int fd = STDERR_FILENO + 1; result == 0 && fd < TTSREADER_MAX_INHERITED_FD; fd++) {
        rc = posix_spawn_file_actions_addclose(&actions, fd);
        if (rc != 0) {
            result = -rc;
        }
    }

    if (result == 0) {
        rc = posix_spawn(pid, path, &actions, NULL, argv, environ);
        if (rc != 0) {
            result = -rc;
        }
    }

    posix_spawn_file_actions_destroy(&actions);
    return result;
}

__attribute__((visibility("default")))
int ttsreader_player_signal(int pid, int signo) {
    if (pid <= 0 || signo <= 0) {
        errno = EINVAL;
        return -1;
    }

    ttsreader_signal_barrier();
    return kill((pid_t)pid, signo);
}

__attribute__((visibility("default")))
int ttsreader_player_alive(int pid) {
    if (pid <= 0) {
        return 0;
    }

    if (kill((pid_t)pid, 0) == 0) {
        return 1;
    }
    return errno == EPERM ? 1 : 0;
}

__attribute__((visibility("default")))
int ttsreader_player_reap(int pid) {
    if (pid <= 0) {
        return 1;
    }

    int status = 0;
    pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
    if (result == 0) {
        return 0;
    }
    if (result == (pid_t)pid) {
        return 1;
    }
    if (errno == ECHILD) {
        if (kill((pid_t)pid, 0) == 0 || errno == EPERM) {
            return 0;
        }
        return 1;
    }
    return -1;
}

__attribute__((visibility("default")))
int ttsreader_player_poll(int pid) {
    if (pid <= 0) {
        errno = EINVAL;
        return -1;
    }

    int status = 0;
    pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
    if (result == 0) {
        return 0;
    }
    if (result == (pid_t)pid) {
        if (WIFEXITED(status)) {
            int code = WEXITSTATUS(status);
            return code == 0 ? 1 : -code;
        }
        if (WIFSIGNALED(status)) {
            return -(128 + WTERMSIG(status));
        }
        return -1;
    }
    if (errno == ECHILD) {
        if (kill((pid_t)pid, 0) == 0 || errno == EPERM) {
            return 0;
        }
        return 1;
    }
    return -1;
}

__attribute__((visibility("default")))
int ttsreader_player_spawn_control(
    const char *player_path,
    const char *audio_path,
    const char *device,
    double speed,
    double seek_seconds,
    double volume,
    const char *volume_control_path) {
    if (!player_path || !*player_path || !audio_path || !*audio_path) {
        errno = EINVAL;
        return -1;
    }
    const char *spawn_device = device && *device ? device : "default";
    if (speed < 0.5) {
        speed = 0.5;
    } else if (speed > 2.0) {
        speed = 2.0;
    }
    if (seek_seconds < 0.0) {
        seek_seconds = 0.0;
    }
    if (volume < 0.2) {
        volume = 0.2;
    } else if (volume > 1.5) {
        volume = 1.5;
    }

    char speed_arg[32];
    char seek_arg[32];
    char volume_arg[32];
    snprintf(speed_arg, sizeof(speed_arg), "%.3f", speed);
    snprintf(seek_arg, sizeof(seek_arg), "%.3f", seek_seconds);
    snprintf(volume_arg, sizeof(volume_arg), "%.3f", volume);

    ttsreader_signal_barrier();
    pid_t pid = (pid_t)-1;
    char *player_argv[16];
    int argi = 0;
    player_argv[argi++] = (char *)player_path;
    player_argv[argi++] = "--quiet";
    player_argv[argi++] = "--device";
    player_argv[argi++] = (char *)spawn_device;
    player_argv[argi++] = "--speed";
    player_argv[argi++] = speed_arg;
    player_argv[argi++] = "--volume";
    player_argv[argi++] = volume_arg;
    if (volume_control_path && *volume_control_path) {
        player_argv[argi++] = "--volume-control";
        player_argv[argi++] = (char *)volume_control_path;
    }
    player_argv[argi++] = "--seek";
    player_argv[argi++] = seek_arg;
    player_argv[argi++] = (char *)audio_path;
    player_argv[argi] = NULL;
    int spawn_rc = ttsreader_spawn_path(player_path, player_argv, &pid);
#if defined(__arm__)
    if (spawn_rc == -EACCES || spawn_rc == -ENOEXEC) {
        char *loader_argv[17];
        argi = 0;
        loader_argv[argi++] = TTSREADER_ARMHF_LOADER;
        loader_argv[argi++] = (char *)player_path;
        loader_argv[argi++] = "--quiet";
        loader_argv[argi++] = "--device";
        loader_argv[argi++] = (char *)spawn_device;
        loader_argv[argi++] = "--speed";
        loader_argv[argi++] = speed_arg;
        loader_argv[argi++] = "--volume";
        loader_argv[argi++] = volume_arg;
        if (volume_control_path && *volume_control_path) {
            loader_argv[argi++] = "--volume-control";
            loader_argv[argi++] = (char *)volume_control_path;
        }
        loader_argv[argi++] = "--seek";
        loader_argv[argi++] = seek_arg;
        loader_argv[argi++] = (char *)audio_path;
        loader_argv[argi] = NULL;
        spawn_rc = ttsreader_spawn_path(TTSREADER_ARMHF_LOADER, loader_argv, &pid);
    }
#endif
    if (spawn_rc != 0) {
        errno = -spawn_rc;
        return spawn_rc;
    }

    ttsreader_lower_child_priority(pid);
    return (int)pid;
}

__attribute__((visibility("default")))
int ttsreader_player_spawn(const char *player_path, const char *audio_path, const char *device, double speed, double seek_seconds, double volume) {
    return ttsreader_player_spawn_control(player_path, audio_path, device, speed, seek_seconds, volume, NULL);
}

__attribute__((visibility("default")))
double ttsreader_player_elapsed(double offset, double wall_delta, double speed) {
    if (offset < 0.0) {
        offset = 0.0;
    }
    if (wall_delta < 0.0) {
        wall_delta = 0.0;
    }
    if (speed < 0.5) {
        speed = 0.5;
    } else if (speed > 2.0) {
        speed = 2.0;
    }
    return offset + wall_delta * speed;
}
