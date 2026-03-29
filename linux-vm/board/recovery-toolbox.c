#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

#define MAX_ARGS 64

struct command_desc {
  const char *name;
  int (*run)(int argc, char **argv);
  const char *summary;
};

static int run_help(int argc, char **argv);
static int run_shell(int argc, char **argv);
static int run_ls(int argc, char **argv);
static int run_cat(int argc, char **argv);
static int run_dmesg(int argc, char **argv);
static int run_sysctl(int argc, char **argv);
static int run_uname_cmd(int argc, char **argv);
static int run_lsmod(int argc, char **argv);
static int run_poweroff_cmd(int argc, char **argv);
static int run_reboot_cmd(int argc, char **argv);

enum parse_state {
  PARSE_NORMAL = 0,
  PARSE_SINGLE_QUOTE,
  PARSE_DOUBLE_QUOTE,
  PARSE_ESCAPE,
  PARSE_ESCAPE_DOUBLE,
};

static const struct command_desc COMMANDS[] = {
    {"help", run_help, "show the available recovery commands"},
    {"sh", run_shell, "start the interactive recovery shell"},
    {"ls", run_ls, "list directory contents"},
    {"cat", run_cat, "print file contents"},
    {"dmesg", run_dmesg, "print the kernel log buffer"},
    {"sysctl", run_sysctl, "read one or more /proc/sys keys"},
    {"uname", run_uname_cmd, "print kernel/system information"},
    {"lsmod", run_lsmod, "print the loaded kernel module list"},
    {"poweroff", run_poweroff_cmd, "power off the VM"},
    {"reboot", run_reboot_cmd, "reboot the VM"},
};

static const char *command_basename(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash != NULL ? slash + 1 : path;
}

static const struct command_desc *find_command(const char *name) {
  size_t i;

  for (i = 0; i < sizeof(COMMANDS) / sizeof(COMMANDS[0]); ++i) {
    if (strcmp(COMMANDS[i].name, name) == 0) {
      return &COMMANDS[i];
    }
  }

  return NULL;
}

static int copy_fd_to_stdout(int fd) {
  char buffer[4096];

  for (;;) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count == 0) {
      return 0;
    }
    if (count < 0) {
      perror("read");
      return 1;
    }
    if (write(STDOUT_FILENO, buffer, (size_t)count) != count) {
      perror("write");
      return 1;
    }
  }
}

static int cat_one(const char *path) {
  int fd;
  int status;

  fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror(path);
    return 1;
  }

  status = copy_fd_to_stdout(fd);
  close(fd);
  return status;
}

static int list_one(const char *path, bool show_header) {
  struct stat st;

  if (lstat(path, &st) != 0) {
    perror(path);
    return 1;
  }

  if (!S_ISDIR(st.st_mode)) {
    printf("%s\n", path);
    return 0;
  }

  if (show_header) {
    printf("%s:\n", path);
  }

  {
    struct dirent **entries = NULL;
    int count = scandir(path, &entries, NULL, alphasort);
    int i;

    if (count < 0) {
      perror(path);
      return 1;
    }

    for (i = 0; i < count; ++i) {
      if (entries[i]->d_name[0] != '.') {
        printf("%s\n", entries[i]->d_name);
      }
      free(entries[i]);
    }
    free(entries);
  }

  return 0;
}

static int list_klog(void) {
  int size = klogctl(10, NULL, 0);
  char *buffer;
  int count;

  if (size <= 0) {
    size = 1 << 20;
  }

  buffer = malloc((size_t)size + 1);
  if (buffer == NULL) {
    perror("malloc");
    return 1;
  }

  count = klogctl(3, buffer, size);
  if (count < 0) {
    perror("dmesg");
    free(buffer);
    return 1;
  }

  buffer[count] = '\0';
  fputs(buffer, stdout);
  if (count == 0 || buffer[count - 1] != '\n') {
    fputc('\n', stdout);
  }
  free(buffer);
  return 0;
}

static int print_sysctl_value(const char *key) {
  char path[PATH_MAX];
  FILE *stream;
  size_t i;
  int ch;
  bool ended_with_newline = false;

  if (snprintf(path, sizeof(path), "/proc/sys/%s", key) >= (int)sizeof(path)) {
    fprintf(stderr, "sysctl key is too long: %s\n", key);
    return 1;
  }

  for (i = strlen("/proc/sys/"); path[i] != '\0'; ++i) {
    if (path[i] == '.') {
      path[i] = '/';
    }
  }

  stream = fopen(path, "r");
  if (stream == NULL) {
    perror(path);
    return 1;
  }

  printf("%s = ", key);
  while ((ch = fgetc(stream)) != EOF) {
    fputc(ch, stdout);
    ended_with_newline = ch == '\n';
  }
  if (!ended_with_newline) {
    fputc('\n', stdout);
  }

  fclose(stream);
  return 0;
}

static int do_reboot(int how, const char *name) {
  sync();
  if (reboot(how) != 0) {
    perror(name);
    return 1;
  }

  return 0;
}

static char *trim_whitespace(char *text) {
  char *end;

  while (*text != '\0' && isspace((unsigned char)*text)) {
    ++text;
  }

  if (*text == '\0') {
    return text;
  }

  end = text + strlen(text) - 1;
  while (end > text && isspace((unsigned char)*end)) {
    *end-- = '\0';
  }

  return text;
}

static int dispatch_command(int argc, char **argv);

static int push_token(char **argv, int *argc, char **token_start, char **write_ptr) {
  if (*token_start == NULL) {
    return 0;
  }

  if (*argc >= MAX_ARGS - 1) {
    fputs("too many arguments for recovery command\n", stderr);
    *token_start = NULL;
    return 1;
  }

  *(*write_ptr)++ = '\0';
  argv[(*argc)++] = *token_start;
  *token_start = NULL;
  return 0;
}

static int parse_next_command(char **cursor, char **argv, int *argc) {
  enum parse_state state = PARSE_NORMAL;
  char *read_ptr = *cursor;
  char *write_ptr;
  char *token_start = NULL;

  *argc = 0;

  while (*read_ptr != '\0' && (*read_ptr == ';' || isspace((unsigned char)*read_ptr))) {
    ++read_ptr;
  }

  *cursor = read_ptr;
  write_ptr = read_ptr;

  for (;;) {
    char ch = *read_ptr;

    switch (state) {
      case PARSE_NORMAL:
        if (ch == '\0' || ch == '\n' || ch == ';') {
          if (push_token(argv, argc, &token_start, &write_ptr) != 0) {
            *cursor = read_ptr;
            argv[*argc] = NULL;
            return 1;
          }
          if (ch == ';') {
            ++read_ptr;
          }
          *cursor = read_ptr;
          argv[*argc] = NULL;
          return 0;
        }
        if (isspace((unsigned char)ch)) {
          if (push_token(argv, argc, &token_start, &write_ptr) != 0) {
            *cursor = read_ptr;
            argv[*argc] = NULL;
            return 1;
          }
          ++read_ptr;
          break;
        }
        if (ch == '\\') {
          if (token_start == NULL) {
            token_start = write_ptr;
          }
          state = PARSE_ESCAPE;
          ++read_ptr;
          break;
        }
        if (ch == '\'') {
          if (token_start == NULL) {
            token_start = write_ptr;
          }
          state = PARSE_SINGLE_QUOTE;
          ++read_ptr;
          break;
        }
        if (ch == '"') {
          if (token_start == NULL) {
            token_start = write_ptr;
          }
          state = PARSE_DOUBLE_QUOTE;
          ++read_ptr;
          break;
        }
        if (token_start == NULL) {
          token_start = write_ptr;
        }
        *write_ptr++ = ch;
        ++read_ptr;
        break;

      case PARSE_SINGLE_QUOTE:
        if (ch == '\0' || ch == '\n') {
          fputs("unterminated single-quoted string\n", stderr);
          *cursor = read_ptr;
          argv[*argc] = NULL;
          return 1;
        }
        if (ch == '\'') {
          state = PARSE_NORMAL;
          ++read_ptr;
          break;
        }
        *write_ptr++ = ch;
        ++read_ptr;
        break;

      case PARSE_DOUBLE_QUOTE:
        if (ch == '\0' || ch == '\n') {
          fputs("unterminated double-quoted string\n", stderr);
          *cursor = read_ptr;
          argv[*argc] = NULL;
          return 1;
        }
        if (ch == '"') {
          state = PARSE_NORMAL;
          ++read_ptr;
          break;
        }
        if (ch == '\\') {
          state = PARSE_ESCAPE_DOUBLE;
          ++read_ptr;
          break;
        }
        *write_ptr++ = ch;
        ++read_ptr;
        break;

      case PARSE_ESCAPE:
      case PARSE_ESCAPE_DOUBLE:
        if (ch == '\0' || ch == '\n') {
          fputs("trailing escape in recovery command\n", stderr);
          *cursor = read_ptr;
          argv[*argc] = NULL;
          return 1;
        }
        *write_ptr++ = ch;
        ++read_ptr;
        state = state == PARSE_ESCAPE ? PARSE_NORMAL : PARSE_DOUBLE_QUOTE;
        break;
    }
  }
}

static int execute_line(char *line) {
  char *cursor = line;
  int status = 0;

  cursor = trim_whitespace(cursor);
  while (*cursor != '\0') {
    char *trimmed;
    char *argv[MAX_ARGS];
    int argc = 0;
    int parse_status;

    parse_status = parse_next_command(&cursor, argv, &argc);
    if (parse_status != 0) {
      status = 1;
    } else if (argc > 0) {
      status = dispatch_command(argc, argv);
    }
    trimmed = trim_whitespace(cursor);
    cursor = trimmed;
  }

  return status;
}

static int run_help(int argc, char **argv) {
  size_t i;

  (void)argc;
  (void)argv;

  puts("Available recovery commands:");
  for (i = 0; i < sizeof(COMMANDS) / sizeof(COMMANDS[0]); ++i) {
    printf("  %-8s %s\n", COMMANDS[i].name, COMMANDS[i].summary);
  }
  puts("  exit     power off the recovery VM");
  puts("  quit     power off the recovery VM");
  return 0;
}

static int run_shell(int argc, char **argv) {
  if (argc == 1 || (argc == 2 && strcmp(argv[1], "-i") == 0)) {
    char *line = NULL;
    size_t line_cap = 0;

    for (;;) {
      int status;

      fputs("(recovery) # ", stdout);
      fflush(stdout);

      if (getline(&line, &line_cap, stdin) < 0) {
        free(line);
        return run_poweroff_cmd(1, argv);
      }

      status = execute_line(line);
      if (status != 0) {
        fflush(stdout);
      }
    }
  }

  if (argc == 3 && strcmp(argv[1], "-c") == 0) {
    return execute_line(argv[2]);
  }

  fputs("usage: sh [-i] | sh -c COMMAND\n", stderr);
  return 1;
}

static int run_ls(int argc, char **argv) {
  int status = 0;
  int i;

  if (argc == 1) {
    return list_one(".", false);
  }

  for (i = 1; i < argc; ++i) {
    if (list_one(argv[i], argc > 2) != 0) {
      status = 1;
    }
    if (argc > 2 && i + 1 < argc) {
      fputc('\n', stdout);
    }
  }

  return status;
}

static int run_cat(int argc, char **argv) {
  int status = 0;
  int i;

  if (argc < 2) {
    fputs("usage: cat PATH [...]\n", stderr);
    return 1;
  }

  for (i = 1; i < argc; ++i) {
    if (cat_one(argv[i]) != 0) {
      status = 1;
    }
  }

  return status;
}

static int run_dmesg(int argc, char **argv) {
  if (argc != 1) {
    fputs("usage: dmesg\n", stderr);
    return 1;
  }

  return list_klog();
}

static int run_sysctl(int argc, char **argv) {
  int status = 0;
  int i;

  if (argc < 2) {
    fputs("usage: sysctl KEY [...]\n", stderr);
    return 1;
  }

  for (i = 1; i < argc; ++i) {
    if (print_sysctl_value(argv[i]) != 0) {
      status = 1;
    }
  }

  return status;
}

static int run_uname_cmd(int argc, char **argv) {
  struct utsname info;

  if (uname(&info) != 0) {
    perror("uname");
    return 1;
  }

  if (argc == 1) {
    printf("%s\n", info.sysname);
    return 0;
  }

  if (argc == 2 && strcmp(argv[1], "-a") == 0) {
    printf("%s %s %s %s %s\n",
           info.sysname,
           info.nodename,
           info.release,
           info.version,
           info.machine);
    return 0;
  }

  fputs("usage: uname [-a]\n", stderr);
  return 1;
}

static int run_lsmod(int argc, char **argv) {
  FILE *stream;
  int ch;
  bool wrote_output = false;

  if (argc != 1) {
    fputs("usage: lsmod\n", stderr);
    return 1;
  }

  stream = fopen("/proc/modules", "r");
  if (stream == NULL) {
    perror("/proc/modules");
    return 1;
  }

  while ((ch = fgetc(stream)) != EOF) {
    fputc(ch, stdout);
    wrote_output = true;
  }

  if (ferror(stream)) {
    perror("/proc/modules");
    fclose(stream);
    return 1;
  }

  fclose(stream);

  if (!wrote_output) {
    puts("(no modules loaded)");
  }

  return 0;
}

static int run_poweroff_cmd(int argc, char **argv) {
  if (argc != 1) {
    fputs("usage: poweroff\n", stderr);
    return 1;
  }

  return do_reboot(RB_POWER_OFF, "poweroff");
}

static int run_reboot_cmd(int argc, char **argv) {
  if (argc != 1) {
    fputs("usage: reboot\n", stderr);
    return 1;
  }

  return do_reboot(RB_AUTOBOOT, "reboot");
}

static int dispatch_command(int argc, char **argv) {
  const struct command_desc *command;

  if (argc == 0 || argv[0] == NULL) {
    return 0;
  }

  if (strcmp(argv[0], "exit") == 0 || strcmp(argv[0], "quit") == 0) {
    if (argc != 1) {
      fprintf(stderr, "usage: %s\n", argv[0]);
      return 1;
    }
    return run_poweroff_cmd(1, argv);
  }

  command = find_command(argv[0]);
  if (command == NULL) {
    fprintf(stderr, "unknown command: %s (use 'help' for the recovery command list)\n", argv[0]);
    return 1;
  }

  return command->run(argc, argv);
}

int main(int argc, char **argv) {
  const char *name = command_basename(argv[0]);

  if (strcmp(name, "recovery-toolbox") == 0 || strcmp(name, "toolbox") == 0) {
    if (argc > 1) {
      return dispatch_command(argc - 1, argv + 1);
    }
    return run_shell(1, argv);
  }

  argv[0] = (char *)name;
  return dispatch_command(argc, argv);
}
