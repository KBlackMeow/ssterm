#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/resource.h>

pid_t pty_forkpty(
    int *master,
    int *slave,
    const struct termios *termp,
    const struct winsize *winp)
{
    int ptm = open("/dev/ptmx", O_RDWR | O_NOCTTY);

    if (ptm < 0)
    {
        return -1;
    }

    fcntl(ptm, F_SETFD, FD_CLOEXEC);

    if (grantpt(ptm) || unlockpt(ptm))
    {
        return -1;
    }

    char *devname;

    if ((devname = ptsname(ptm)) == NULL)
    {
        return -1;
    }

    int pts = open(devname, O_RDWR | O_NOCTTY);
    if (pts < 0)
    {
        return -1;
    }

    if (termp)
    {
        tcsetattr(pts, TCSAFLUSH, termp);
    }

    if (winp)
    {
        ioctl(pts, TIOCSWINSZ, winp);
    }

    pid_t pid = fork();

    if (pid < 0)
    {
        return -1;
    }

    if (pid == 0)
    {
        setsid();
        if (ioctl(pts, TIOCSCTTY, (char *)NULL) == -1)
            exit(-1);

        dup2(pts, STDIN_FILENO);
        dup2(pts, STDOUT_FILENO);
        dup2(pts, STDERR_FILENO);

        if (pts > 2)
        {
            close(pts);
        }

        // Close all file descriptors inherited from the parent process.
        // Without this, the Flutter/Dart VM's internal fds (pipes, sockets,
        // etc.) leak into the child shell, pushing it toward ulimit -n and
        // causing errors like "cannot duplicate fd 1: too many open files".
        //
        // Enumerate the live fd table rather than blindly looping to rlimit:
        //   macOS exposes open fds under /dev/fd
        //   Linux  exposes open fds under /proc/self/fd
        // Collect all fds first, then close, so iterating the directory is
        // not disturbed by closing entries mid-scan.
#if defined(__APPLE__)
        const char *fd_dir = "/dev/fd";
#else
        const char *fd_dir = "/proc/self/fd";
#endif
        int closed_via_dir = 0;
        DIR *fddir = opendir(fd_dir);
        if (fddir != NULL)
        {
            int to_close[1024];
            int n = 0;
            int dfd = dirfd(fddir);
            struct dirent *de;
            while ((de = readdir(fddir)) != NULL)
            {
                if (de->d_name[0] == '.') continue;
                int fd = atoi(de->d_name);
                if (fd >= 3 && fd != dfd && n < 1024)
                    to_close[n++] = fd;
            }
            closedir(fddir);
            for (int i = 0; i < n; i++) close(to_close[i]);
            closed_via_dir = 1;
        }
        if (!closed_via_dir)
        {
            // Fallback: /dev/fd or /proc unavailable (chroot, container, etc.)
            struct rlimit rl;
            getrlimit(RLIMIT_NOFILE, &rl);
            for (int fd = 3; fd < (int)rl.rlim_cur; fd++) close(fd);
        }
    }
    else
    {
        *master = ptm;
        if (slave)
        {
            *slave = pts;
        }
    }

    return pid;
}
