# Source from the repository root: . ./scripts/flint3e-env.sh
# Linux builds use their existing host environment.
if [ "$(uname -s)" = Darwin ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo 'Homebrew is required; install it and add brew to PATH first.' >&2
        return 1
    fi
    flint3e_brew_prefix=$(brew --prefix) || return 1
    for flint3e_formula in coreutils findutils gnu-tar gnu-sed grep gawk make bash gnu-getopt diffutils gpatch; do
        flint3e_opt="$flint3e_brew_prefix/opt/$flint3e_formula"
        if [ ! -d "$flint3e_opt" ]; then
            echo "Missing Homebrew dependency: $flint3e_formula (run scripts/bootstrap-flint3e.sh)" >&2
            return 1
        fi
        PATH="$flint3e_opt/libexec/gnubin:$flint3e_opt/bin:$PATH"
    done
    PATH="$flint3e_brew_prefix/bin:$PATH"
    PKG_CONFIG_PATH="$flint3e_brew_prefix/opt/ncurses/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    FLINT3E_GO_BOOTSTRAP_ROOT="$flint3e_brew_prefix/opt/go/libexec"
    export PATH PKG_CONFIG_PATH FLINT3E_GO_BOOTSTRAP_ROOT
    unset flint3e_brew_prefix flint3e_formula flint3e_opt
fi
