#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CONFIG_LIMIT (1024U * 1024U)
#define CLEANUP_GRACE_SECONDS 5
#define MAX_TIMEOUT_SECONDS 3600

static volatile sig_atomic_t received_signal = 0;

static void remember_signal(int signal_number) {
  received_signal = signal_number;
}

static int64_t monotonic_milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return -1;
  }
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void print_usage(void) {
  fputs("usage: CodexBarStagingLauncher --timeout-seconds N --provider ID "
        "--source web|api|oauth|cli --mode usage|diagnose\n",
        stderr);
}

enum command_mode {
  COMMAND_MODE_UNSET = 0,
  COMMAND_MODE_USAGE,
  COMMAND_MODE_DIAGNOSE,
};

static enum command_mode parse_command_mode(const char *value) {
  if (strcmp(value, "usage") == 0) {
    return COMMAND_MODE_USAGE;
  }
  if (strcmp(value, "diagnose") == 0) {
    return COMMAND_MODE_DIAGNOSE;
  }
  return COMMAND_MODE_UNSET;
}

static bool valid_provider(const char *value) {
  size_t length = strlen(value);
  if (length == 0 || length > 64) {
    return false;
  }
  for (size_t index = 0; index < length; index++) {
    char character = value[index];
    if (!((character >= 'a' && character <= 'z') ||
          (character >= '0' && character <= '9') || character == '-')) {
      return false;
    }
  }
  return true;
}

static bool valid_source(const char *value) {
  return strcmp(value, "web") == 0 || strcmp(value, "api") == 0 ||
         strcmp(value, "oauth") == 0 || strcmp(value, "cli") == 0;
}

static bool parse_timeout(const char *value, int *result) {
  char *end = NULL;
  errno = 0;
  long parsed = strtol(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed < 1 ||
      parsed > MAX_TIMEOUT_SECONDS) {
    return false;
  }
  *result = (int)parsed;
  return true;
}

static int create_config_fd(void) {
  int descriptor;
#if defined(SYS_memfd_create) && !defined(CODEXBAR_TEST_DISABLE_MEMFD)
  descriptor = (int)syscall(SYS_memfd_create, "codexbar-config",
                            MFD_CLOEXEC | MFD_ALLOW_SEALING);
  if (descriptor >= 0) {
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
      int saved_errno = errno;
      close(descriptor);
      errno = saved_errno;
      return -1;
    }
    return descriptor;
  }
#endif

  char path[] = "/tmp/.codexbar-config-XXXXXX";
  descriptor = mkstemp(path);
  if (descriptor < 0) {
    return -1;
  }
  int mode_result = fchmod(descriptor, S_IRUSR | S_IWUSR);
  int mode_errno = errno;
  int unlink_result = unlink(path);
  int unlink_errno = errno;
  if (mode_result != 0 || unlink_result != 0) {
    close(descriptor);
    errno = mode_result != 0 ? mode_errno : unlink_errno;
    return -1;
  }
  int flags = fcntl(descriptor, F_GETFD);
  if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0) {
    int saved_errno = errno;
    close(descriptor);
    errno = saved_errno;
    return -1;
  }
  return descriptor;
}

static int read_config(int descriptor, int64_t deadline_ms) {
  uint8_t buffer[16384];
  size_t total = 0;
  for (;;) {
    int64_t now = monotonic_milliseconds();
    if (now < 0 || now >= deadline_ms) {
      errno = ETIMEDOUT;
      return -1;
    }
    int remaining = (int)(deadline_ms - now);
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP};
    int poll_result = poll(&input, 1, remaining);
    if (poll_result == 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    if (poll_result < 0) {
      if (errno == EINTR && received_signal == 0) {
        continue;
      }
      return -1;
    }

    ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (count == 0) {
      break;
    }
    if (count < 0) {
      if (errno == EINTR && received_signal == 0) {
        continue;
      }
      return -1;
    }
    if (total + (size_t)count > CONFIG_LIMIT) {
      memset(buffer, 0, sizeof(buffer));
      errno = EFBIG;
      return -1;
    }
    size_t offset = 0;
    while (offset < (size_t)count) {
      ssize_t written =
          write(descriptor, buffer + offset, (size_t)count - offset);
      if (written < 0) {
        if (errno == EINTR) {
          continue;
        }
        memset(buffer, 0, sizeof(buffer));
        return -1;
      }
      offset += (size_t)written;
    }
    total += (size_t)count;
    memset(buffer, 0, sizeof(buffer));
  }
  if (total == 0) {
    errno = EINVAL;
    return -1;
  }
  if (lseek(descriptor, 0, SEEK_SET) < 0) {
    return -1;
  }
#ifdef F_ADD_SEALS
  (void)fcntl(descriptor, F_ADD_SEALS,
              F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_WRITE | F_SEAL_SEAL);
#endif
  return 0;
}

static int launcher_directory(char *result, size_t capacity) {
  char executable[PATH_MAX];
  ssize_t count =
      readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (count <= 0 || (size_t)count >= sizeof(executable) - 1) {
    return -1;
  }
  executable[count] = '\0';
  char *slash = strrchr(executable, '/');
  if (slash == NULL) {
    errno = EINVAL;
    return -1;
  }
  *slash = '\0';
  if (snprintf(result, capacity, "%s", executable) >= (int)capacity) {
    errno = ENAMETOOLONG;
    return -1;
  }
  return 0;
}

static void close_nonstdio_descriptors(void) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, 3U, ~0U, 0U) == 0) {
    return;
  }
#endif
  DIR *directory = opendir("/proc/self/fd");
  if (directory != NULL) {
    int directory_fd = dirfd(directory);
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
      char *end = NULL;
      long descriptor = strtol(entry->d_name, &end, 10);
      if (*entry->d_name != '\0' && end != entry->d_name && *end == '\0' &&
          descriptor > STDERR_FILENO && descriptor != directory_fd) {
        close((int)descriptor);
      }
    }
    closedir(directory);
    return;
  }
  long maximum = sysconf(_SC_OPEN_MAX);
  if (maximum < 0 || maximum > 1048576) {
    maximum = 65536;
  }
  for (int descriptor = STDERR_FILENO + 1; descriptor < maximum; descriptor++) {
    close(descriptor);
  }
}

static void cleanup_process_group(pid_t child, int64_t cleanup_deadline_ms) {
  if (kill(-child, 0) != 0 && errno == ESRCH) {
    return;
  }
  (void)kill(-child, SIGTERM);
  for (;;) {
    int status;
    while (waitpid(-child, &status, WNOHANG) > 0) {
    }
    if (kill(-child, 0) != 0 && errno == ESRCH) {
      return;
    }
    int64_t now = monotonic_milliseconds();
    if (now < 0 || now >= cleanup_deadline_ms) {
      (void)kill(-child, SIGKILL);
      while (waitpid(-child, &status, WNOHANG) > 0) {
      }
      return;
    }
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
    (void)nanosleep(&pause, NULL);
  }
}

static int wait_for_child(pid_t child, int64_t deadline_ms) {
  int status = 0;
  bool terminating = false;
  bool timed_out = false;
  int64_t kill_deadline = 0;
  for (;;) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) {
      int64_t now = monotonic_milliseconds();
      int64_t cleanup_deadline =
          terminating ? kill_deadline : now + CLEANUP_GRACE_SECONDS * 1000;
      cleanup_process_group(child, cleanup_deadline);
      if (timed_out) {
        return 124;
      }
      if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
      }
      if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
      }
      return 125;
    }
    if (result < 0 && errno != EINTR) {
      return 125;
    }

    int64_t now = monotonic_milliseconds();
    bool expired = now < 0 || now >= deadline_ms;
    if (!terminating && (received_signal != 0 || expired)) {
      terminating = true;
      timed_out = received_signal == 0 && expired;
      kill_deadline = now + CLEANUP_GRACE_SECONDS * 1000;
      (void)kill(-child, SIGTERM);
    } else if (terminating && (now < 0 || now >= kill_deadline)) {
      (void)kill(-child, SIGKILL);
    }

    struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
    (void)nanosleep(&pause, NULL);
    if (terminating && now >= kill_deadline + 1000) {
      (void)waitpid(child, &status, 0);
      return received_signal != 0 ? 128 + received_signal : 124;
    }
  }
}

int main(int argc, char **argv) {
  int timeout_seconds = 0;
  const char *provider = NULL;
  const char *source = NULL;
  enum command_mode command_mode = COMMAND_MODE_UNSET;
  if (argc != 9) {
    print_usage();
    return 64;
  }
  for (int index = 1; index < argc; index += 2) {
    if (strcmp(argv[index], "--timeout-seconds") == 0 && timeout_seconds == 0) {
      if (!parse_timeout(argv[index + 1], &timeout_seconds)) {
        fputs("invalid timeout\n", stderr);
        return 64;
      }
    } else if (strcmp(argv[index], "--provider") == 0 && provider == NULL) {
      provider = argv[index + 1];
    } else if (strcmp(argv[index], "--source") == 0 && source == NULL) {
      source = argv[index + 1];
    } else if (strcmp(argv[index], "--mode") == 0 &&
               command_mode == COMMAND_MODE_UNSET) {
      command_mode = parse_command_mode(argv[index + 1]);
      if (command_mode == COMMAND_MODE_UNSET) {
        fputs("invalid command mode\n", stderr);
        return 64;
      }
    } else {
      fputs("invalid or repeated argument\n", stderr);
      return 64;
    }
  }
  if (timeout_seconds == 0 || provider == NULL || !valid_provider(provider) ||
      source == NULL || !valid_source(source) ||
      command_mode == COMMAND_MODE_UNSET) {
    fputs("invalid launcher arguments\n", stderr);
    return 64;
  }

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = remember_signal;
  sigemptyset(&action.sa_mask);
  (void)sigaction(SIGINT, &action, NULL);
  (void)sigaction(SIGTERM, &action, NULL);
  (void)sigaction(SIGHUP, &action, NULL);

  int64_t started = monotonic_milliseconds();
  int64_t deadline = started + (int64_t)timeout_seconds * 1000;
  int config_fd = create_config_fd();
  if (config_fd < 0) {
    perror("could not create anonymous config descriptor");
    return 125;
  }
  if (read_config(config_fd, deadline) != 0) {
    int saved_errno = errno;
    close(config_fd);
    if (received_signal != 0) {
      return 128 + received_signal;
    }
    if (saved_errno == EFBIG) {
      fputs("config exceeds launcher limit\n", stderr);
      return 65;
    }
    if (saved_errno == ETIMEDOUT) {
      fputs("launcher timed out while reading config\n", stderr);
      return 124;
    }
    errno = saved_errno;
    perror("could not stage config");
    return 65;
  }

  char directory[PATH_MAX];
  char cli_path[PATH_MAX];
  char config_path[64];
  if (launcher_directory(directory, sizeof(directory)) != 0 ||
      snprintf(cli_path, sizeof(cli_path), "%s/CodexBarCLI", directory) >=
          (int)sizeof(cli_path) ||
      snprintf(config_path, sizeof(config_path), "/proc/%ld/fd/%d",
               (long)getpid(), config_fd) >= (int)sizeof(config_path)) {
    close(config_fd);
    fputs("could not resolve bundled CLI path\n", stderr);
    return 125;
  }
  struct stat cli_stat;
  if (stat(cli_path, &cli_stat) != 0 || !S_ISREG(cli_stat.st_mode) ||
      access(cli_path, X_OK) != 0) {
    close(config_fd);
    fputs("release-matched bundled CLI is unavailable\n", stderr);
    return 126;
  }

  pid_t child = fork();
  if (child < 0) {
    close(config_fd);
    perror("could not start bundled CLI");
    return 125;
  }
  if (child == 0) {
    (void)setpgid(0, 0);
    if (setenv("CODEXBAR_CONFIG", config_path, 1) != 0) {
      _exit(125);
    }
    close_nonstdio_descriptors();
    if (command_mode == COMMAND_MODE_DIAGNOSE) {
      char *const cli_arguments[] = {
          cli_path,         "diagnose", "--provider", (char *)provider,
          "--format",       "json",     "--redact",   NULL,
      };
      execv(cli_path, cli_arguments);
    } else {
      char *const cli_arguments[] = {
          cli_path,         "usage",      "--provider",
          (char *)provider, "--source",   (char *)source,
          "--json",         "--no-color", NULL,
      };
      execv(cli_path, cli_arguments);
    }
    _exit(errno == ENOENT ? 127 : 126);
  }
  (void)setpgid(child, child);
  int exit_code = wait_for_child(child, deadline);
  close(config_fd);
  if (received_signal != 0) {
    return 128 + received_signal;
  }
  return exit_code;
}
