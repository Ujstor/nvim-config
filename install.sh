#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/Ujstor/nvim-config.git"
NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
TREE_SITTER_VERSION="v0.26.8"

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

# 1. Prerequisites: compiler, make, git, curl, ripgrep, fd, unzip
missing_pkgs=()
command -v cc      >/dev/null 2>&1 || missing_pkgs+=(build-essential)
command -v make    >/dev/null 2>&1 || missing_pkgs+=(make)
command -v git     >/dev/null 2>&1 || missing_pkgs+=(git)
command -v curl    >/dev/null 2>&1 || missing_pkgs+=(curl)
command -v rg      >/dev/null 2>&1 || missing_pkgs+=(ripgrep)
command -v unzip   >/dev/null 2>&1 || missing_pkgs+=(unzip)
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

# 2. tree-sitter CLI (required by nvim-treesitter main branch to compile parsers)
if ! command -v tree-sitter >/dev/null 2>&1; then
    echo "Installing tree-sitter CLI ${TREE_SITTER_VERSION}"
    arch=$(uname -m)
    case "$arch" in
        x86_64)         ts_arch=x64 ;;
        aarch64|arm64)  ts_arch=arm64 ;;
        *) echo "Unsupported arch for tree-sitter: $arch"; exit 1 ;;
    esac
    ts_tmp=$(mktemp -d)
    curl -sSL "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-linux-${ts_arch}.gz" -o "$ts_tmp/tree-sitter.gz"
    gunzip -f "$ts_tmp/tree-sitter.gz"
    need_sudo install -m 755 "$ts_tmp/tree-sitter" /usr/local/bin/tree-sitter
    rm -rf "$ts_tmp"
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
