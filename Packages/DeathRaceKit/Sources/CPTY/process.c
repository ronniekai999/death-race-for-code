#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#endif

pid_t cpty_foreground_group(int master_fd) {
    return tcgetpgrp(master_fd);
}

int cpty_process_name(pid_t pid, char *buffer, size_t size) {
    if (buffer == NULL || size < 2) {
        errno = EINVAL;
        return -1;
    }
#if defined(__APPLE__)
    errno = 0;
    int length = proc_name(pid, buffer, (uint32_t)size);
    if (length <= 0) {
        if (errno == 0) errno = ESRCH;
        return -1;
    }
    buffer[(size_t)length < size ? (size_t)length : size - 1] = '\0';
    return 0;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/comm", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t length = read(fd, buffer, size - 1);
    int saved = errno;
    close(fd);
    if (length < 0) {
        errno = saved;
        return -1;
    }
    while (length > 0 && buffer[length - 1] == '\n') length--;
    buffer[length] = '\0';
    return 0;
#endif
}

int cpty_process_cwd(pid_t pid, char *buffer, size_t size) {
    if (buffer == NULL || size < 2) {
        errno = EINVAL;
        return -1;
    }
#if defined(__APPLE__)
    struct proc_vnodepathinfo info;
    errno = 0;
    int got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, (int)sizeof info);
    if (got != (int)sizeof info) {
        if (errno == 0) errno = ESRCH;
        return -1;
    }
    size_t length = strnlen(info.pvi_cdir.vip_path, sizeof info.pvi_cdir.vip_path);
    if (length == 0) {
        errno = ENOENT;
        return -1;
    }
    if (length >= size) {
        errno = ERANGE;
        return -1;
    }
    memcpy(buffer, info.pvi_cdir.vip_path, length);
    buffer[length] = '\0';
    return 0;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cwd", (int)pid);
    ssize_t length = readlink(path, buffer, size - 1);
    if (length < 0) return -1;
    if ((size_t)length >= size - 1) {
        errno = ERANGE;
        return -1;
    }
    buffer[length] = '\0';
    return 0;
#endif
}
