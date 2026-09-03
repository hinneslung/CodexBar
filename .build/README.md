# Local build layout

This directory has one stable convention. Do not add feature-named, agent-named, or dated build
directories here.

## SwiftPM output

Use the repository's default SwiftPM build directory:

```powershell
swift build --product CodexBar
swift test
```

The current native Windows debug executable is always:

```text
.build/x86_64-unknown-windows-msvc/debug/CodexBar.exe
```

Its bundled Linux CLI payload belongs beside it at:

```text
.build/x86_64-unknown-windows-msvc/debug/wsl-cli/
```

`artifacts`, `checkouts`, `repositories`, the target-triple directories, `build.db`, the YAML files,
and the `debug`/`release` links are managed by SwiftPM. `lint-tools` is managed by the repository lint
scripts.

## Windows release material

Keep custom Windows artifacts under one namespace only:

```text
.build/windows/release-inputs/<architecture>/<version>/
.build/windows/releases/<version>/<architecture>/
```

Do not put runnable debug copies or QA evidence in this namespace.

## Temporary tests and QA

Focused-test scratch directories and screenshots do not belong in the repository build directory.
Reuse these stable external locations:

```text
%TEMP%/CodexBar/swiftpm/
%TEMP%/CodexBar/qa/
```

Before creating any new build directory, prefer one of the locations above. If neither fits, update
this README with a durable category first instead of inventing a one-off folder.
