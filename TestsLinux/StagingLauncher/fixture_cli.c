#define _GNU_SOURCE

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *config = getenv("CODEXBAR_CONFIG");
  if (config == NULL) {
    return 20;
  }
  FILE *input = fopen(config, "r");
  if (input == NULL) {
    return 21;
  }
  char value[128] = {0};
  if (fread(value, 1, sizeof(value) - 1, input) == 0) {
    return 22;
  }
  fclose(input);
  if (strcmp(value, "{\"canary\":\"stdin-only\"}") != 0) {
    return 23;
  }
  const char *expected_usage[] = {
      "CodexBarCLI", "usage", "--provider", "fixture",
      "--source",    "web",   "--json",     "--no-color",
  };
  const char *expected_diagnose[] = {
      "CodexBarCLI", "diagnose", "--provider", "fixture",
      "--format",    "json",     "--redact",
  };
  const char **expected = expected_usage;
  int expected_count = 8;
  const char *success = "fixture-ok";
  if (argc > 1 && strcmp(argv[1], "diagnose") == 0) {
    expected = expected_diagnose;
    expected_count = 7;
    success = "fixture-diagnose-ok";
  }
  if (argc != expected_count) {
    return 24;
  }
  for (int index = 1; index < argc; index++) {
    if (index == 3 && (strcmp(argv[index], "slow") == 0 ||
                       strcmp(argv[index], "crash") == 0)) {
      continue;
    }
    if (strcmp(argv[index], expected[index]) != 0) {
      return 25;
    }
  }
  if (strcmp(argv[3], "slow") == 0) {
    sleep(30);
  }
  if (strcmp(argv[3], "crash") == 0) {
    pid_t descendant = fork();
    if (descendant == 0) {
      sleep(30);
      return 0;
    }
    if (descendant < 0) {
      return 41;
    }
    return 42;
  }
  DIR *directory = opendir("/proc/self/fd");
  if (directory == NULL) {
    return 26;
  }
  int directory_fd = dirfd(directory);
  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    int descriptor = atoi(entry->d_name);
    if (descriptor > STDERR_FILENO && descriptor != directory_fd) {
      return 27;
    }
  }
  closedir(directory);
  puts(success);
  return 0;
}
