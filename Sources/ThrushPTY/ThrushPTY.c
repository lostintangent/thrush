#include "ThrushPTY.h"
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int thrush_spawn(const char *executable, const char *shell, const char *directory, char *const environment[],
                 int columns, int rows, pid_t *pid, int *master, dev_t *device) {
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    int slave;
    char name[128];
    if (openpty(master, &slave, name, NULL, &size) < 0) return errno;
    // Open the slave in the new session to give interactive shells a controlling terminal.
    posix_spawn_file_actions_t files;
    posix_spawnattr_t attr;
    struct stat info;
    int error = 0;
    if (fstat(slave, &info) < 0 || fcntl(*master, F_SETFL, O_NONBLOCK) < 0) { error = errno; goto close_pty; }
    *device = info.st_rdev;
    if ((error = posix_spawn_file_actions_init(&files))) goto close_pty;
    if ((error = posix_spawnattr_init(&attr))) goto free_files;
    sigset_t signals, mask;
    sigfillset(&signals);
    sigemptyset(&mask);
    error = posix_spawnattr_setsigdefault(&attr, &signals);
    if (!error) error = posix_spawnattr_setsigmask(&attr, &mask);
    if (!error) error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                                 POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    if (!error) error = posix_spawn_file_actions_addchdir(&files, directory);
    if (!error) error = posix_spawn_file_actions_addopen(&files, 0, name, O_RDWR, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&files, 0, 1);
    if (!error) error = posix_spawn_file_actions_adddup2(&files, 0, 2);
    char *const argv[] = {(char *)executable, "--pty-child", (char *)shell, NULL};
    if (!error) error = posix_spawn(pid, executable, &files, &attr, argv, environment);
    posix_spawnattr_destroy(&attr);
free_files:
    posix_spawn_file_actions_destroy(&files);
close_pty:
    close(slave);
    if (error) close(*master);
    return error;
}

void thrush_resize(int master, int columns, int rows) {
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    ioctl(master, TIOCSWINSZ, &size);
}

int thrush_available(int master) {
    int bytes = 0;
    return ioctl(master, FIONREAD, &bytes) == 0 ? bytes : 0;
}

// Darwin clears a shell's controlling tty when its session leader exits. A small
// supervisor retains that session until it has also ended the shell's background jobs.
static void kill_jobs(dev_t device, pid_t leader) {
    int capacity = proc_listpids(PROC_TTY_ONLY, device, NULL, 0) + 32 * sizeof(pid_t);
    pid_t *jobs = malloc(capacity);
    if (!jobs) return;
    int bytes = proc_listpids(PROC_TTY_ONLY, device, jobs, capacity);
    for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
        if (jobs[i] > 1 && jobs[i] != leader && getsid(jobs[i]) == leader) kill(jobs[i], SIGKILL);
    }
    free(jobs);
}

int thrush_run_child(const char *shell) {
    struct stat tty;
    pid_t leader = getpid(), child;
    if (shell[0] != '/' || getsid(0) != leader || !isatty(0) || fstat(0, &tty) != 0) return 126;
    if (tcgetsid(0) != leader && ioctl(0, TIOCSCTTY, 0) < 0) return 126;
    char *const argv[] = {(char *)shell, NULL};
    if (posix_spawn(&child, shell, NULL, NULL, argv, *_NSGetEnviron()) != 0) return 127;
    // The child inherits normal dispositions. Only it should react to interactive signals.
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    int status = 0;
    while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
    kill_jobs(tty.st_rdev, leader);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

void thrush_close(int master, pid_t pid, dev_t device) {
    kill_jobs(device, pid);
    close(master); // An exiting child may itself be waiting for the PTY to close.
    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
}
