## Install

```bash
curl -sSL https://raw.githubusercontent.com/Ujstor/nvim-config/master/install.sh | bash
```

The installer takes care of:

- System packages: `build-essential` / `make` / `git` / `curl` / `ripgrep` / `fd` / `unzip`
  (auto-detects `apt`, `dnf`, or `pacman`).
- `tree-sitter` CLI (required by nvim-treesitter `main` branch to compile parsers).
- Latest Neovim release (Linux x86_64) into `/usr/local`.
- Cloning this config to `~/.config/nvim`.
- Headless `:Lazy sync` and treesitter parser install so the first launch is clean.

## Update

After updating Neovim or pulling config changes:

```
:Lazy sync
:lua require('nvim-treesitter').update():wait(600000)
```

## Notes

- nvim-treesitter is on the `main` branch (the rewrite). On `main`, `setup()` no longer
  accepts `ensure_installed` / `auto_install`. The list of parsers lives in
  `lua/parsers.lua` and is installed via `require('nvim-treesitter').install(...)`
  from `lua/essential/treesitter.lua`.
- Requires Neovim 0.12+.
