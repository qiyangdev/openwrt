#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/check-flint3e-image.py" "$@"
