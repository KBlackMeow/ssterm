#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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
        struct rlimit rl;
        getrlimit(RLIMIT_NOFILE, &rl);
        int maxfd = (int)(rl.rlim_cur < 4096 ? rl.rlim_cur : 4096);
        for (int fd = 3; fd < maxfd; fd++)
        {
            close(fd);
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
