#!/bin/sh
# Prepare the macOS host and build the complete personal firmware.
set -eu

case "${1:-}" in
    -h|--help)
        cat <<'HELP'
Usage: ./scripts/bootstrap-flint3e.sh

Installs host dependencies, prepares a case-sensitive checkout, updates feeds,
builds the firmware and validates the image. No firmware is flashed.

Environment overrides:
  FLINT3E_JOBS        Parallel build jobs (default: 4)
  FLINT3E_IMAGE       Sparsebundle path (default: $HOME/OpenWrt.sparsebundle)
  FLINT3E_IMAGE_SIZE  New image capacity (default: 100g)

Run from an existing complete checkout. Local uncommitted changes are included.
On macOS, Command Line Tools and Homebrew may require interactive installation.
HELP
        exit 0 ;;
    '') ;;
    *) echo 'Unknown argument. Use --help.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo 'Unexpected arguments.' >&2; exit 1; }

source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -d "$source_root/.git" ] || {
    echo 'Run this script from a complete Git checkout, not a source archive.' >&2
    exit 1
}

# Test the filesystem itself instead of assuming a volume name implies its type.
is_case_sensitive() (
    probe=$(mktemp -d "$1/.flint3e-fs.XXXXXX") || exit 1
    trap 'rm -rf "$probe"' EXIT HUP INT TERM
    touch "$probe/lowercase"
    [ ! -e "$probe/LOWERCASE" ]
)

if [ "$(uname -s)" = Darwin ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
        xcode-select --install
        echo 'Finish installing Command Line Tools, then run this script again.' >&2
        exit 1
    fi
    if ! command -v brew >/dev/null 2>&1; then
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        else
            installer=$(mktemp "${TMPDIR:-/tmp}/flint3e-homebrew.XXXXXX")
            trap 'rm -f "$installer"' EXIT HUP INT TERM
            curl -fSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
            /bin/bash "$installer"
            rm -f "$installer"
            trap - EXIT HUP INT TERM
            if [ -x /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            else
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi
    fi
    brew install coreutils findutils gnu-tar gnu-sed grep gawk make bash \
        gnu-getopt diffutils gpatch wget pkgconf ncurses go python git rsync
fi
. "$source_root/scripts/flint3e-env.sh"

build_root=$source_root
if ! is_case_sensitive "$source_root"; then
    [ "$(uname -s)" = Darwin ] || {
        echo 'Move the checkout to a case-sensitive filesystem and retry.' >&2
        exit 1
    }
    image=${FLINT3E_IMAGE:-"$HOME/OpenWrt.sparsebundle"}
    case "$image" in /*) ;; *) echo 'FLINT3E_IMAGE must be an absolute path.' >&2; exit 1 ;; esac
    if [ ! -e "$image" ]; then
        hdiutil create -size "${FLINT3E_IMAGE_SIZE:-100g}" -type SPARSEBUNDLE \
            -fs 'Case-sensitive APFS' -volname OpenWrt "$image"
    fi
    # Read the actual mount point, including already mounted images and duplicate names.
    mount_root=$(python3 - "$image" <<'PY'
import os
import plistlib
import subprocess
import sys
image = os.path.realpath(sys.argv[1])
info = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))
for entry in info.get('images', []):
    if os.path.realpath(entry.get('image-path', '')) == image:
        for entity in entry.get('system-entities', []):
            if entity.get('mount-point'):
                print(entity['mount-point'])
                sys.exit(0)
attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-plist', image]))
for entity in attached.get('system-entities', []):
    if entity.get('mount-point'):
        print(entity['mount-point'])
        sys.exit(0)
sys.exit('No mounted filesystem found in the disk image')
PY
    )
    is_case_sensitive "$mount_root" || {
        echo 'The disk image is not case-sensitive.' >&2; exit 1
    }
    build_root="$mount_root/openwrt-personal"
    marker="$build_root/.flint3e-build-source"
    if [ -e "$build_root" ]; then
        [ -f "$marker" ] && [ "$(cat "$marker")" = "$source_root" ] || {
            echo "Refusing to overwrite an unmanaged checkout: $build_root" >&2
            exit 1
        }
    else
        mkdir "$build_root"
        printf '%s\n' "$source_root" > "$marker"
    fi
    echo "Synchronizing complete source checkout to $build_root"
    # Anchored exclusions preserve build caches without excluding package/firmware.
    # This managed mirror is replaced from the source; edit the source checkout only.
    rsync -a --delete \
        --exclude='/.flint3e-build-source' \
        --exclude='/bin/' --exclude='/build_dir/' --exclude='/staging_dir/' \
        --exclude='/tmp/' --exclude='/logs/' --exclude='/dl/' \
        --exclude='/feeds/' --exclude='/package/feeds/' --exclude='/firmware/' \
        --exclude='/.config' --exclude='/.config.old' \
        "$source_root/" "$build_root/"
fi

cd "$build_root"
echo "Building branch: $(git branch --show-current)"
echo "Build checkout: $build_root"
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/build-flint3e.sh V=s
printf '\nValidated firmware: %s\n' \
    "$build_root/bin/targets/qualcommbe/ipq53xx/openwrt-qualcommbe-ipq53xx-glinet_gl-be6500-squashfs-sysupgrade.bin"
