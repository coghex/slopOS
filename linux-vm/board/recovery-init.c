#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

static void fail(const char *message) {
  perror(message);
  _exit(1);
}

static void ensure_dir(const char *path, mode_t mode) {
  if (mkdir(path, mode) == 0 || errno == EEXIST) {
    return;
  }

  fail(path);
}

static void ensure_char_device(const char *path, mode_t mode, unsigned int major_id, unsigned int minor_id) {
  struct stat st;

  if (stat(path, &st) == 0) {
    if (S_ISCHR(st.st_mode)) {
      return;
    }

    if (unlink(path) != 0) {
      fail(path);
    }
  } else if (errno != ENOENT) {
    fail(path);
  }

  if (mknod(path, S_IFCHR | mode, makedev(major_id, minor_id)) != 0) {
    fail(path);
  }
}

static void mount_if_needed(const char *source, const char *target, const char *filesystem) {
  if (mount(source, target, filesystem, 0, NULL) == 0 || errno == EBUSY) {
    return;
  }

  fail(target);
}

static void write_banner(void) {
  static const char banner[] =
      "slopOS recovery mode\n"
      "Available commands: help, sh, ls, cat, dmesg, sysctl, uname, lsmod, poweroff, reboot\n\n";

  ssize_t ignored = write(STDOUT_FILENO, banner, sizeof(banner) - 1);
  (void)ignored;
}

int main(void) {
  const char *term = getenv("TERM");
  int console_fd;
  char *const argv[] = {"/bin/sh", "-i", NULL};

  setenv("PATH", "/bin", 1);
  setenv("HOME", "/root", 1);
  setenv("PS1", "(recovery) # ", 1);
  setenv("TERM", term != NULL ? term : "vt100", 1);

  ensure_dir("/dev", 0755);
  ensure_dir("/proc", 0755);
  ensure_dir("/sys", 0755);
  ensure_dir("/root", 0755);

  mount_if_needed("devtmpfs", "/dev", "devtmpfs");
  ensure_char_device("/dev/console", 0600, 5, 1);
  ensure_char_device("/dev/null", 0666, 1, 3);
  ensure_char_device("/dev/ttyAMA0", 0600, 204, 64);
  mount_if_needed("proc", "/proc", "proc");
  mount_if_needed("sysfs", "/sys", "sysfs");

  console_fd = open("/dev/ttyAMA0", O_RDWR);
  if (console_fd < 0) {
    console_fd = open("/dev/console", O_RDWR);
  }

  if (console_fd < 0) {
    fail("open console");
  }

  if (dup2(console_fd, STDIN_FILENO) < 0 ||
      dup2(console_fd, STDOUT_FILENO) < 0 ||
      dup2(console_fd, STDERR_FILENO) < 0) {
    fail("dup2 console");
  }

  if (console_fd > STDERR_FILENO) {
    close(console_fd);
  }

  if (chdir("/root") != 0) {
    fail("chdir /root");
  }

  write_banner();
  execv("/bin/sh", argv);
  fail("exec /bin/sh");
}
