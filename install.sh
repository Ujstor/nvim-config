#!/bin/bash

temp_dir=$(mktemp -d)
git clone --depth 1 https://github.com/Ujstor/nvim-config.git "$temp_dir"

cd "$temp_dir"

curl -sSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz | sudo tar -xz -C /usr/local --strip-components=1

if [ -L /usr/bin/nvim ]; then
    sudo rm /usr/bin/nvim
fi

if [ ! -L /usr/bin/nvim ]; then
    sudo ln -s /usr/local/bin/nvim /usr/bin/nvim
else
    echo "Symbolic link /usr/bin/nvim already exists."
fi

if [ -d ~/.config/nvim ]; then
    rm -rf ~/.config/nvim/*
else
    mkdir -p ~/.config/nvim
fi

cp -r * ~/.config/nvim/

echo "Neovim setup complete."

rm -rf "$temp_dir"

