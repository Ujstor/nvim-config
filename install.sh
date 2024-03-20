#!/bin/bash

if [ -x "$(command -v nvim)" ]; then
    sudo rm -rf /usr/local/bin/nvim
    sudo rm -rf /usr/bin/nvim
    sudo rm -rf /usr/local/share/nvim
    sudo rm -rf /usr/share/nvim
fi

if [ -d ~/.config/nvim ]; then
    rm -rf ~/.config/nvim
fi

temp_dir=$(mktemp -d)
git clone --depth 1 https://github.com/Ujstor/nvim-config.git "$temp_dir"

cd "$temp_dir"

curl -sSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz | sudo tar -xz -C /usr/local --strip-components=1

sudo ln -s /usr/local/bin/nvim /usr/bin/nvim

mkdir -p ~/.config/nvim

cp -r * ~/.config/nvim/

echo "Neovim setup complete."

rm -rf "$temp_dir"
