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

/// Returns 1 when the terminal reads a line with echo off (ICANON on, ECHO off), the way
/// password prompts read (sudo, ssh, getpass); 0 otherwise; -1 with errno set. Echo alone
/// is not enough: shells' line editors turn echo off at every prompt, but they read in raw
/// mode. The master's termios reflects what the program on the slave asked for.
int cpty_password_mode(int master_fd);

/// A descriptor that becomes readable when process `pid` exits, for waiting on it with
/// poll() alongside other descriptors: a kqueue with EVFILT_PROC on macOS, a pidfd on Linux.
/// Close-on-exec. Returns -1 with errno set where neither is available.
int cpty_exit_watch(pid_t pid);

/// The terminal's foreground process group, asked of the master side (TIOCGPGRP, which
/// both kernels answer for a master without it being anyone's controlling terminal).
/// Returns the group id, or -1 with errno set.
pid_t cpty_foreground_group(int master_fd);

/// The short name of process `pid` (what `ps -c` shows), NUL-terminated in `buffer`.
/// Returns 0, or -1 with errno set.
int cpty_process_name(pid_t pid, char *buffer, size_t size);

/// The working directory of process `pid`, NUL-terminated in `buffer`. Returns 0, or -1 with
/// errno set (ERANGE when it does not fit).
int cpty_process_cwd(pid_t pid, char *buffer, size_t size);

#ifdef __cplusplus
}
#endif

#endif
