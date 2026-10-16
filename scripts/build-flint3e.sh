#!/bin/sh
# Build in this checkout. Do not copy selected source directories with rsync.
set -eu
# Accept verbosity settings only; non-build targets could validate a stale image.
for argument in "$@"; do
    case "$argument" in
        V=*) ;;
        *) echo 'Only V= verbosity arguments are supported; set FLINT3E_JOBS for concurrency.' >&2; exit 1 ;;
    esac
done
jobs=${FLINT3E_JOBS:-4}
case "$jobs" in
    ''|*[!0-9]*|0) echo 'FLINT3E_JOBS must be a positive integer.' >&2; exit 1 ;;
esac
[ "$jobs" -gt 0 ] || { echo 'FLINT3E_JOBS must be a positive integer.' >&2; exit 1; }
cd "$(dirname "$0")/.."
. ./scripts/flint3e-env.sh
if command -v gmake >/dev/null 2>&1; then make_cmd=gmake; else make_cmd=make; fi
if [ -f .config ]; then
    backup=$(mktemp "${TMPDIR:-/tmp}/flint3e-config.XXXXXX")
    cp .config "$backup"
    echo "Previous configuration saved to $backup"
fi
cp configs/flint3e.config .config
if [ "$(uname -s)" = Darwin ] && [ -x "${FLINT3E_GO_BOOTSTRAP_ROOT:-}/bin/go" ]; then
    printf '%s\n' "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"$FLINT3E_GO_BOOTSTRAP_ROOT\"" \
        '# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set' >> .config
fi
"$make_cmd" defconfig
python3 scripts/check-flint3e-image.py --config .config
"$make_cmd" -j"$jobs" "$@" world
./scripts/check-flint3e-image.sh
