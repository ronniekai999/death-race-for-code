#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Spawns `path` as the session leader of a new pseudo-terminal.
///
/// `argv` and `envp` are NULL-terminated. `cwd` may be NULL to inherit the caller's.
/// On success returns 0 and stores the master side (non-blocking, close-on-exec) in
/// `*master_fd` and the child's pid in `*child_pid`. On failure returns -1 with errno set;
/// a failed exec shows up later as the child exiting with status 127.
int cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               unsigned short rows, unsigned short cols,
               unsigned short xpixel, unsigned short ypixel,
               int *master_fd, pid_t *child_pid);

/// Tells the terminal (and so the foreground process group, via SIGWINCH) its new size.
/// Returns 0, or -1 with errno set.
int cpty_set_size(int master_fd, unsigned short rows, unsigned short cols,
                  unsigned short xpixel, unsigned short ypixel);

/// Reads the size the terminal currently reports. Returns 0, or -1 with errno set.
int cpty_get_size(int master_fd, unsigned short *rows, unsigned short *cols);

/// Returns 1 when the terminal has ECHO off (a password prompt), 0 when it is on,
/// or -1 with errno set. On macOS the master and slave share one tty, so the master's
/// termios reflects what the program on the slave asked for.
int cpty_echo_disabled(int master_fd);

#ifdef __cplusplus
}
#endif

#endif
