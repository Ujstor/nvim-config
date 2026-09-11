## Install

```bash
curl -sSL https://raw.githubusercontent.com/Ujstor/nvim-config/master/install.sh | bash
```

The installer takes care of:

- System packages: `git` / `curl` / `ripgrep` / `fd` / `unzip` (auto-detects `apt`,
  `dnf`, `pacman`, `zypper` or `apk`). A C toolchain plus `libclang` (bindgen needs
  it) is pulled in only if the `tree-sitter` CLI actually has to be built.
- `tree-sitter` CLI, pinned (required by nvim-treesitter `main` to compile parsers).
  Built with `cargo`, bootstrapping `rustup` first if there is no `cargo`.
- A **pinned** Neovim release into `/usr/local` (x86_64 and arm64), checksum-verified.
- This config into `~/.config/nvim`.
- Headless `:Lazy sync` and treesitter parser install so the first launch is clean.

It is safe to re-run: every step is idempotent, and anything it replaces is backed
up to a timestamped path next to the original first.

### Options

```bash
curl -sSL .../install.sh | bash -s -- --help
```

| Flag | Effect |
| --- | --- |
| `--replace-distro` | Remove a package-manager neovim **through** the package manager, so `/usr/local/bin/nvim` is the only one left. Without it the packaged neovim is left alone and you are told which one PATH resolves. |
| `--nvim-version VER` | Install another tag. The recorded checksum only covers the pinned tag; set `NVIM_SHA256` too, or it installs unverified. |
| `--skip-neovim` | Install only the config. |
| `--skip-bootstrap` | Skip the headless `:Lazy sync` / parser install. |
| `--force` | Replace `~/.config/nvim` even when it is a symlink (e.g. managed by `linux-devops-tools`). Backed up first. |

Environment equivalents: `NVIM_VERSION`, `NVIM_SHA256`, `TREE_SITTER_VERSION`,
`NVIM_SKIP_NEOVIM=1`, `NVIM_SKIP_BOOTSTRAP=1`.

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
- Neovim publishes no checksum of its own, so the sha256 in `install.sh` is one this
  repo recorded from the published artefact. It catches a corrupted or tampered
  download; it is not an upstream signature. Bump the pin and the digests together.
- On a hardened host with `/tmp` mounted `noexec`, the rustup bootstrap and the cargo
  build are run from a probed exec-capable directory instead — the installer says so once
  when it has to fall back off `/tmp`.
