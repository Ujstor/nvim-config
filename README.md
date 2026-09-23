## Install

```bash
curl -sSL https://raw.githubusercontent.com/Ujstor/nvim-config/master/install.sh | bash
```

The installer takes care of:

- System packages: `git` / `curl` / `ripgrep` / `fd` / `unzip` and a C compiler, since
  every treesitter parser is compiled on the host (auto-detects `apt`, `dnf`, `pacman`,
  `zypper` or `apk`). Where the compiler is gcc 12 (Debian 12) it adds `clang`: gcc 12
  needs over 25 minutes for the `gitcommit` parser, and the config builds parsers with
  clang whenever it is installed. The rest of the toolchain, `libclang` included
  (bindgen needs it), is pulled in only if the `tree-sitter` CLI has to be built.
- `tree-sitter` CLI, pinned (required by nvim-treesitter `main` to compile parsers).
  Built with `cargo`, bootstrapping `rustup` first if there is no `cargo`, and copied
  root-owned to `/usr/local/bin/tree-sitter` so root's nvim finds it too.
- A **pinned** Neovim release into `/usr/local` (x86_64 and arm64), checksum-verified and
  unpacked by root. Without usable `sudo` this step is skipped with a note, and the rest
  still runs.
- This config into `~/.config/nvim`.
- A headless plugin install, at the `lazy-lock.json` pins when there is one, and the
  treesitter parser install, so the first launch is clean. A parser that fails to build
  is reported, with the log in `~/.cache/nvim-config/parsers.log`.

It is safe to re-run: every step is idempotent, and anything it replaces is backed up
to a timestamped path next to the original first. A re-run never upgrades plugins;
that is `:Lazy sync`, below.

### Options

```bash
curl -sSL .../install.sh | bash -s -- --help
```

| Flag | Effect |
| --- | --- |
| `--replace-distro` | Remove a package-manager neovim **through** the package manager, so `/usr/local/bin/nvim` is the only one left. Without it the packaged neovim is left alone and you are told which one PATH resolves. |
| `--nvim-version VER` | Install another tag. The recorded checksum only covers the pinned tag; set `NVIM_SHA256` too, or it installs unverified. |
| `--skip-neovim` | Install only the config. |
| `--skip-bootstrap` | Skip the headless plugin / parser install. |
| `--force` | Replace `~/.config/nvim` even when it is a symlink (e.g. managed by `linux-devops-tools`). Backed up first. |

Environment equivalents: `NVIM_VERSION`, `NVIM_SHA256`, `TREE_SITTER_VERSION`,
`NVIM_SKIP_NEOVIM=1`, `NVIM_SKIP_BOOTSTRAP=1`.

## Update

After updating Neovim or pulling config changes, inside nvim:

```
:Lazy sync
:TSUpdate
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
- Before 2026-09-23 this installer copied Neovim into `/usr/local` in a way that made the
  user who ran it the owner of `/usr/local` itself and of everything Neovim put there,
  and it linked `/usr/local/bin/tree-sitter` to `~/.cargo/bin`. Both let that user run
  code as root. Re-running it repairs both: it reinstalls Neovim as root, gives those
  directories back to root and replaces the link with a root-owned copy.
- With `debug = true` in `copilotChat.lua` (removed on 2026-09-23), CopilotChat logged
  the GitHub token in cleartext to `~/.local/state/nvim/CopilotChat.log`. Delete that
  file wherever you used CopilotChat.
