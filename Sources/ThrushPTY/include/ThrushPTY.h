#ifndef THRUSH_PTY_H
#define THRUSH_PTY_H
#include <sys/types.h>

int thrush_run_child(const char *shell);
int thrush_spawn(const char *executable, const char *shell, const char *directory, char *const environment[],
                 int columns, int rows, pid_t *pid, int *master, dev_t *device);
void thrush_resize(int master, int columns, int rows);
int thrush_available(int master);
void thrush_close(int master, pid_t pid, dev_t device);
#endif
