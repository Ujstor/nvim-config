#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/Ujstor/nvim-config.git"
NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
TREE_SITTER_VERSION="0.26.8"

need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_pkgs() {
    if command -v apt-get >/dev/null 2>&1; then
        need_sudo apt-get update -y
        need_sudo apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        need_sudo dnf install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then
        need_sudo pacman -S --needed --noconfirm "$@"
    else
        echo "WARNING: Unknown package manager. Please install manually: $*"
    fi
}

# 1. Prerequisites: compiler, make, git, curl, ripgrep, fd, unzip, clang (for tree-sitter cargo build)
missing_pkgs=()
command -v cc      >/dev/null 2>&1 || missing_pkgs+=(build-essential)
command -v make    >/dev/null 2>&1 || missing_pkgs+=(make)
command -v git     >/dev/null 2>&1 || missing_pkgs+=(git)
command -v curl    >/dev/null 2>&1 || missing_pkgs+=(curl)
command -v rg      >/dev/null 2>&1 || missing_pkgs+=(ripgrep)
command -v unzip   >/dev/null 2>&1 || missing_pkgs+=(unzip)
command -v clang   >/dev/null 2>&1 || missing_pkgs+=(clang libclang-dev pkg-config libssl-dev)

# fd is `fd-find` on Debian/Ubuntu, `fd` elsewhere
if ! command -v fd >/dev/null 2>&1 && ! command -v fdfind >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        missing_pkgs+=(fd-find)
    else
        missing_pkgs+=(fd)
    fi
fi

if [ ${#missing_pkgs[@]} -gt 0 ]; then
    echo "Installing prerequisites: ${missing_pkgs[*]}"
    install_pkgs "${missing_pkgs[@]}"
fi

# 2. tree-sitter CLI (compiled via cargo for glibc compatibility across distros)
if ! command -v tree-sitter >/dev/null 2>&1; then
    echo "Installing Rust toolchain (if missing)"
    if ! command -v cargo >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable --profile minimal
    fi
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

    echo "Installing tree-sitter CLI ${TREE_SITTER_VERSION} via cargo (this takes a few minutes)"
    cargo install --locked tree-sitter-cli --version "${TREE_SITTER_VERSION}"

    # Make it available system-wide for headless nvim later in the script
    need_sudo ln -sf "$HOME/.cargo/bin/tree-sitter" /usr/local/bin/tree-sitter
fi

# 3. Remove any prior neovim install
if [ -x "$(command -v nvim)" ]; then
    need_sudo rm -rf /usr/local/bin/nvim
    need_sudo rm -rf /usr/bin/nvim
    need_sudo rm -rf /usr/local/share/nvim
    need_sudo rm -rf /usr/share/nvim
fi

if [ -d ~/.config/nvim ]; then
    rm -rf ~/.config/nvim
fi

# 4. Install Neovim
echo "Installing Neovim"
curl -sSL "$NVIM_URL" | need_sudo tar -xz -C /usr/local --strip-components=1
need_sudo ln -sf /usr/local/bin/nvim /usr/bin/nvim

# 5. Pull config
temp_dir=$(mktemp -d)
git clone --depth 1 "$REPO_URL" "$temp_dir"
mkdir -p ~/.config/nvim
(cd "$temp_dir" && cp -r . ~/.config/nvim/)
rm -rf ~/.config/nvim/.git ~/.config/nvim/.github 2>/dev/null || true
rm -rf "$temp_dir"

# 6. Pre-install plugins and treesitter parsers headlessly so first launch is clean
echo "Bootstrapping plugins (lazy.nvim sync)"
nvim --headless "+Lazy! sync" +qa 2>/dev/null || true

echo "Bootstrapping treesitter parsers (this can take a few minutes)"
nvim --headless -c 'lua require("nvim-treesitter").install(require("parsers")):wait(600000)' +qa 2>&1 | tail -5 || true

echo
echo "Neovim setup complete. Launch with: nvim"
