# CodexBar Linux staging launcher

This Windows-port-owned helper stages one minimal upstream config and invokes the unchanged, release-matched
`CodexBarCLI` installed beside it. It contains no provider implementation.

The invocation contract is:

```text
CodexBarStagingLauncher --timeout-seconds N --provider ID --source web|api|oauth|cli
```

`N` is 1 through 3600. `ID` is a canonical lowercase provider ID containing only ASCII letters, digits, and
hyphens. Arguments may contain exactly those three flag/value pairs, once each. The complete config is read from
stdin up to EOF, with a 1 MiB limit. The launcher constructs this fixed child invocation:

```text
CodexBarCLI usage --provider ID --source SOURCE --json --no-color
```

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
`TestsLinux/StagingLauncher/test_unchanged_cli_routes.sh` therefore traces the release-matched unchanged CLI for
every enabled API route, every Windows-exposed manual web route, and each environment-projected OpenCode bridge
route. The release job fails if a route executes anything except the staging launcher and its sibling CLI, or if a
credential canary reaches argv or captured output. A new route must be added to that gate before Windows exposes it.
