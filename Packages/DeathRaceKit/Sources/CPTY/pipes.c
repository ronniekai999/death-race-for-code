// pipe2() and struct ucred need these on glibc.
#define _GNU_SOURCE

#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/un.h>
#else
#include <sys/syscall.h>
#endif

#ifndef NSIG
#define NSIG 32
#endif

static int highest_fd(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0 || rl.rlim_cur == RLIM_INFINITY || rl.rlim_cur > 65536) {
        return 65536;
    }
    return (int)rl.rlim_cur;
}

// A close-on-exec pipe whose ends sit above the standard descriptors, so the child's dup2()
// onto 0, 1 and 2 can never overwrite an end it still needs.
static int make_pipe(int fds[2]) {
    int raw[2];
#if defined(__linux__)
    if (pipe2(raw, O_CLOEXEC) != 0) return -1;
#else
    if (pipe(raw) != 0) return -1;
    (void)fcntl(raw[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(raw[1], F_SETFD, FD_CLOEXEC);
#endif
    for (int i = 0; i < 2; i++) {
        if (raw[i] < 3) {
            int moved = fcntl(raw[i], F_DUPFD_CLOEXEC, 3);
            int saved = errno;
            close(raw[i]);
            if (moved < 0) {
                if (i == 0) close(raw[1]);
                else close(fds[0]);
                errno = saved;
                return -1;
            }
            raw[i] = moved;
        }
        fds[i] = raw[i];
    }
    return 0;
}

static void close_pair(int fds[2]) {
    if (fds[0] >= 0) close(fds[0]);
    if (fds[1] >= 0) close(fds[1]);
}

// Waits for the end of file that the child's execve() or exit brings, at most 2 seconds:
// on macOS another thread's fork() between pipe() and fcntl() could hold the write end.
static void wait_until_started(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN, .revents = 0};
    for (;;) {
        int ready = poll(&p, 1, 2000);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return;
        char byte;
        ssize_t got = read(fd, &byte, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return;
    }
}

int cpty_spawn_pipes(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     int new_session, pid_t *child_pid,
                     int *stdin_fd, int *stdout_fd, int *stderr_fd) {
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    if (make_pipe(in) != 0) return -1;
    if (make_pipe(out) != 0) {
        int saved = errno;
        close_pair(in);
        errno = saved;
        return -1;
    }
    if (make_pipe(err) != 0) {
        int saved = errno;
        close_pair(in);
        close_pair(out);
        errno = saved;
        return -1;
    }
    // Closed by the child's execve() (or its exit): until then the parent waits, so the
    // child has its own session and process group by the time this returns.
    int started[2] = {-1, -1};
    if (make_pipe(started) != 0) {
        int saved = errno;
        close_pair(in);
        close_pair(out);
        close_pair(err);
        errno = saved;
        return -1;
    }

    // Everything the child uses is prepared before fork(): afterwards only async-signal-safe
    // calls may run, and an app parent has threads holding locks.
    const int max_fd = highest_fd();
    struct sigaction dfl;
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigset_t all, previous, none;
    sigfillset(&all);
    sigemptyset(&none);
    pthread_sigmask(SIG_SETMASK, &all, &previous);

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
        close_pair(in);
        close_pair(out);
        close_pair(err);
        close_pair(started);
        errno = saved;
        return -1;
    }

    if (pid == 0) {
        for (int s = 1; s < NSIG; s++) {
            if (s == SIGKILL || s == SIGSTOP) continue;
            (void)sigaction(s, &dfl, NULL);
        }
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (new_session && setsid() < 0) _exit(126);
        if (dup2(in[0], STDIN_FILENO) < 0 || dup2(out[1], STDOUT_FILENO) < 0 ||
            dup2(err[1], STDERR_FILENO) < 0) {
            _exit(126);
        }
        // The started pipe becomes descriptor 3, still close-on-exec; everything above goes.
        if (started[1] != 3 && dup2(started[1], 3) < 0) _exit(126);
        (void)fcntl(3, F_SETFD, FD_CLOEXEC);
#if defined(__linux__) && defined(SYS_close_range)
        if (syscall(SYS_close_range, 4U, ~0U, 0U) != 0)
#endif
        {
            for (int fd = 4; fd < max_fd; fd++) close(fd);
        }
        if (cwd != NULL) (void)chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    close(in[0]);
    close(out[1]);
    close(err[1]);
    close(started[1]);
    wait_until_started(started[0]);
    close(started[0]);
    *child_pid = pid;
    *stdin_fd = in[1];
    *stdout_fd = out[0];
    *stderr_fd = err[0];
    return 0;
}

ssize_t cpty_write_no_sigpipe(int fd, const void *buffer, size_t count) {
#if defined(__APPLE__)
    (void)fcntl(fd, F_SETNOSIGPIPE, 1);
    return write(fd, buffer, count);
#else
    sigset_t pipe_only, previous, pending;
    sigemptyset(&pipe_only);
    sigaddset(&pipe_only, SIGPIPE);
    // A SIGPIPE already pending belongs to someone else's write: leave it alone.
    sigemptyset(&pending);
    (void)sigpending(&pending);
    int already_pending = sigismember(&pending, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_only, &previous);
    ssize_t written = write(fd, buffer, count);
    int saved = errno;
    if (written < 0 && saved == EPIPE && !already_pending) {
        struct timespec zero = {0, 0};
        while (sigtimedwait(&pipe_only, NULL, &zero) < 0 && errno == EINTR) {
        }
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved;
    return written;
#endif
}

int cpty_peer_audit_token(int socket_fd, uint32_t token[8]) {
#if defined(__APPLE__)
    // Eight words rather than audit_token_t, so this needs no extra header: the type is
    // exactly `struct { unsigned int val[8]; }`. The length is checked in case that changes.
    uint32_t audit[8];
    socklen_t length = sizeof audit;
    if (getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERTOKEN, audit, &length) != 0) return -1;
    if (length != sizeof audit) {
        errno = EINVAL;
        return -1;
    }
    memcpy(token, audit, sizeof audit);
    return 0;
#else
    (void)socket_fd;
    (void)token;
    errno = ENOTSUP;  // nothing to check a token against where there is no code signing
    return -1;
#endif
}

int cpty_peer_credentials(int socket_fd, pid_t *pid, uid_t *uid) {
#if defined(__APPLE__)
    pid_t peer = 0;
    socklen_t length = sizeof peer;
    if (getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) != 0) return -1;
    uid_t user;
    gid_t group;
    if (getpeereid(socket_fd, &user, &group) != 0) return -1;
    *pid = peer;
    *uid = user;
    return 0;
#else
    struct ucred credentials;
    socklen_t length = sizeof credentials;
    if (getsockopt(socket_fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) return -1;
    *pid = credentials.pid;
    *uid = credentials.uid;
    return 0;
#endif
}
