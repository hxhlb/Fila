#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Every image Fila ships: the app and its share extension, the daemon, the
# root-run archive helper, the module frameworks and the package sources —
# Objective-C and C++ shims included.
hits="$(grep -RnE --include='*.swift' --include='*.c' --include='*.h' \
    --include='*.m' --include='*.mm' --include='*.cpp' --include='*.cc' \
    '\b(fork|forkpty|vfork|execv|execve|execvp|execvpe|execl|execle|execlp)[[:space:]]*\(|POSIX_SPAWN_SETEXEC' \
    "$root/Fila" "$root/FilaSaveAction" "$root/Filad" "$root/FilaArchive" "$root/Frameworks" \
    "$root/Packages/FilaKit/Sources" || true)"
if [[ -n "$hits" ]]; then
    echo 'error: Fila must use ordinary posix_spawn without process replacement:' >&2
    echo "$hits" >&2
    exit 65
fi
