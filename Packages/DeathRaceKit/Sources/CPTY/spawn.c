#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#include <sys/syscall.h>
#endif

#ifndef NSIG
#define NSIG 32
#endif

// Highest descriptor the child might have inherited. Computed before fork(), because
// getrlimit is not on the async-signal-safe list.
static int highest_fd_to_close(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0 || rl.rlim_cur == RLIM_INFINITY || rl.rlim_cur > 65536) {
        return 65536;
    }
    return (int)rl.rlim_cur;
}

int cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               unsigned short rows, unsigned short cols,
               unsigned short xpixel, unsigned short ypixel,
               int *master_fd, pid_t *child_pid) {
    int master = -1, slave = -1;
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = xpixel;
    ws.ws_ypixel = ypixel;

    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) {
        return -1;
    }

    // UTF-8 line discipline, so canonical-mode erase removes whole characters.
    struct termios t;
    if (tcgetattr(slave, &t) == 0) {
#ifdef IUTF8
        t.c_iflag |= IUTF8;
#endif
        (void)tcsetattr(slave, TCSANOW, &t);
    }

    // Everything the child uses is prepared here: after fork() only async-signal-safe
    // functions may run, and an app parent has threads holding locks we must not touch.
    const int max_fd = highest_fd_to_close();
    struct sigaction dfl;
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigset_t all, previous, none;
    sigfillset(&all);
    sigemptyset(&none);

    // Block signals across fork() so the child never runs one of the parent's handlers
    // before it has reset them.
    pthread_sigmask(SIG_SETMASK, &all, &previous);

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
        close(master);
        close(slave);
        errno = saved;
        return -1;
    }

    if (pid == 0) {
        // Child: GUI parents ignore SIGPIPE and friends; a shell expects defaults.
        for (int s = 1; s < NSIG; s++) {
            if (s == SIGKILL || s == SIGSTOP) continue;
            (void)sigaction(s, &dfl, NULL);
        }
        sigprocmask(SIG_SETMASK, &none, NULL);

        if (setsid() < 0) _exit(126);
        if (ioctl(slave, TIOCSCTTY, 0) < 0) _exit(126);
        if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) {
            _exit(126);
        }

#if defined(__linux__) && defined(SYS_close_range)
        if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0)
#endif
        {
            for (int fd = 3; fd < max_fd; fd++) close(fd);
        }

        if (cwd != NULL) (void)chdir(cwd);  // a missing directory leaves the shell where it is
        execve(path, argv, envp);
        _exit(127);
    }

    // Parent.
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    close(slave);

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) (void)fcntl(master, F_SETFL, flags | O_NONBLOCK);
    (void)fcntl(master, F_SETFD, FD_CLOEXEC);

    *master_fd = master;
    *child_pid = pid;
    return 0;
}

int cpty_set_size(int master_fd, unsigned short rows, unsigned short cols,
                  unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = xpixel;
    ws.ws_ypixel = ypixel;
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

int cpty_get_size(int master_fd, unsigned short *rows, unsigned short *cols) {
    struct winsize ws;
    if (ioctl(master_fd, TIOCGWINSZ, &ws) != 0) return -1;
    *rows = ws.ws_row;
    *cols = ws.ws_col;
    return 0;
}

int cpty_echo_disabled(int master_fd) {
    struct termios t;
    if (tcgetattr(master_fd, &t) != 0) return -1;
    return (t.c_lflag & ECHO) ? 0 : 1;
}
