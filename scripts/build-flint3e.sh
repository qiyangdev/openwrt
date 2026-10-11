#!/bin/sh
# Build in this checkout. Do not copy selected source directories with rsync.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Darwin ]; then
    PATH="/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/bin:$PATH"
    PKG_CONFIG_PATH="/opt/homebrew/opt/ncurses/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export PATH PKG_CONFIG_PATH
fi
if command -v gmake >/dev/null 2>&1; then make_cmd=gmake; else make_cmd=make; fi
if [ -f .config ]; then
    backup=$(mktemp "${TMPDIR:-/tmp}/flint3e-config.XXXXXX")
    cp .config "$backup"
    echo "Previous configuration saved to $backup"
fi
cp configs/flint3e.config .config
if [ "$(uname -s)" = Darwin ] && [ -x /opt/homebrew/opt/go/libexec/bin/go ]; then
    printf '%s\n' 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/opt/homebrew/opt/go/libexec"' \
        '# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set' >> .config
fi
"$make_cmd" defconfig
python3 scripts/check-flint3e-image.py --config .config
"$make_cmd" -j"${FLINT3E_JOBS:-4}" "$@"
./scripts/check-flint3e-image.sh
