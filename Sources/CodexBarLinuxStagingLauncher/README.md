# CodexBar Linux staging launcher

This Windows-port-owned helper stages one minimal upstream config and invokes the unchanged, release-matched
`CodexBarCLI` installed beside it. It contains no provider implementation.

The invocation contract is:

```text
CodexBarStagingLauncher --timeout-seconds N --provider ID --source auto|web|api|oauth|cli --mode usage|diagnose
```

`N` is 1 through 3600. `ID` is a canonical lowercase provider ID containing only ASCII letters, digits, and
hyphens. Arguments must contain exactly those four flag/value pairs, once each. The complete config is read from
stdin up to EOF, with a 1 MiB limit. The launcher constructs one of these fixed child invocations:

```text
CodexBarCLI usage --provider ID --source SOURCE --json --no-color
CodexBarCLI diagnose --provider ID --format json --redact
```

The `diagnose` command reads its source from the staged config; the launcher's `--source` remains required.

`auto` is used for nonsecret per-profile Codex home configuration while retaining the CLI's normal automatic
OAuth/CLI fallback and Automatic source attribution.

It uses `memfd_create`, falling back to a mode-0600 temporary file unlinked before any config byte is written. The
watchdog owns the descriptor and exposes `/proc/<watchdog-pid>/fd/<fd>` through `CODEXBAR_CONFIG` only to the CLI
environment. The CLI child closes all non-stdio inherited descriptors before `exec`. Timeout returns 124 after
terminating the CLI process group, with a five-second forced-cleanup grace.

Release builds require a musl sysroot (the same Swift Static Linux SDK sysroot used for the matching CLI) or an
explicit musl compiler:

```bash
bash Scripts/build_linux_staging_launcher.sh x86_64 \
  output/CodexBarStagingLauncher-linux-musl-x86_64 /path/to/x86_64-musl-sysroot
bash Scripts/build_linux_staging_launcher.sh aarch64 \
  output/CodexBarStagingLauncher-linux-musl-aarch64 /path/to/aarch64-musl-sysroot
```

Each command verifies the ELF machine, rejects `PT_INTERP`, and writes a neighboring `.sha256`. Windows release
packaging accepts only the launcher whose architecture matches its Linux CLI payload and installs it as
`wsl-cli/CodexBarStagingLauncher`.

The launcher cannot selectively remove `CODEXBAR_CONFIG` from processes spawned internally by the unchanged CLI.
`TestsLinux/StagingLauncher/test.sh` checks the launcher's argument contract, staging, timeouts and cleanup using
a fixture CLI. These offline tests do not certify live provider authentication.
