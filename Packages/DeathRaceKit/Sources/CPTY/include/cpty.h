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

/// Spawns `path` with its standard input, output and error on pipes, for programs that need
/// no terminal: ssh masters, ssh-keygen, sc_auth. With `new_session` the child calls setsid()
/// first, so it has no controlling terminal and its whole process group (jump hops included)
/// can be signalled at once.
///
/// `argv` and `envp` are NULL-terminated; `cwd` may be NULL to inherit the caller's. On
/// success returns 0 and stores the parent's ends, all close-on-exec and blocking: the write
/// end of the child's input in `*stdin_fd`, and the read ends of its output and errors in
/// `*stdout_fd` and `*stderr_fd`. Returns -1 with errno set on failure; a failed exec shows up
/// later as the child exiting with status 127. Every other descriptor is closed in the child.
int cpty_spawn_pipes(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     int new_session, pid_t *child_pid,
                     int *stdin_fd, int *stdout_fd, int *stderr_fd);

/// Writes like write(2), but a reader that has gone away returns -1 with EPIPE instead of
/// killing the process with SIGPIPE (F_SETNOSIGPIPE on macOS; SIGPIPE blocked around the
/// write, and the pending one consumed, on Linux).
ssize_t cpty_write_no_sigpipe(int fd, const void *buffer, size_t count);

/// The process and user at the other end of a connected Unix-domain socket: LOCAL_PEERPID
/// and getpeereid() on macOS, SO_PEERCRED on Linux. Returns 0, or -1 with errno set.
int cpty_peer_credentials(int socket_fd, pid_t *pid, uid_t *uid);

/// The parent of process `pid` (PROC_PIDTBSDINFO on macOS, /proc/<pid>/stat on Linux), or -1
/// with errno set.
pid_t cpty_parent_pid(pid_t pid);

#ifdef __cplusplus
}
#endif

#endif
