#!/bin/bash

curl -sSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz | sudo tar -xz -C /usr/local --strip-components=1 --wildcards '*/bin/*'

if [ -L /usr/bin/nvim ]; then
    sudo rm /usr/bin/nvim
fi

sudo ln -s /usr/local/bin/nvim /usr/bin/nvim

if [ -d ~/.config/nvim ]; then
    rm -rf ~/.config/nvim/*
else
    mkdir -p ~/.config/nvim
fi

cp -r * ~/.config/nvim/

echo "Neovim setup complete."
