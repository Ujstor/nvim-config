#!/usr/bin/env bash
#
# install.sh — set up github.com/Ujstor/nvim-config on this host.
#
#   curl -sSL https://raw.githubusercontent.com/Ujstor/nvim-config/master/install.sh | bash
#   curl -sSL https://raw.githubusercontent.com/Ujstor/nvim-config/master/install.sh | bash -s -- --replace-distro
#   ./install.sh --help
#
# In order it:
#   1. installs the prerequisites this config needs (git, curl, ripgrep, fd,
#      unzip, a C toolchain)
#   2. makes sure the pinned tree-sitter CLI is present — building it with cargo,
#      and bootstrapping rustup first when there is no cargo
#   3. installs the PINNED neovim release into /usr/local
#   4. backs up ~/.config/nvim, then installs this repo there
#   5. runs :Lazy sync and the treesitter parser install headlessly, so the first
#      launch is clean
#
# Safe to re-run. Every step is idempotent, anything it replaces is backed up to
# a timestamped path next to the original first, and nothing owned by
# dpkg/rpm/pacman is ever deleted behind the package manager's back.

set -euo pipefail

REPO_URL="https://github.com/Ujstor/nvim-config.git"
REPO_BRANCH="master"

# An explicit PIN, not `releases/latest`. The previous version of this script
# fetched .../releases/latest/download/..., so two runs a week apart installed two
# different neovims and nothing recorded which. Bump this line deliberately.
NVIM_VERSION="${NVIM_VERSION:-v0.12.5}"

# sha256 of the release tarballs FOR THE PINNED VERSION ABOVE.
#
# Said plainly, because it matters: neovim publishes no checksum of its own.
# Verified for v0.12.5 — the release carries only the tarballs, appimages,
# .zsync, .msi and .zip files, and the release notes contain install steps, no
# sums. So these digests were recorded by this repository from the published
# artefacts on 2026-09-11. They are a trust-on-first-use pin: they catch a
# truncated, corrupted or MITM'd download, they do NOT prove upstream shipped
# what it meant to ship, because there is no upstream signature to check against.
#
# They are enforced only while NVIM_VERSION still equals NVIM_PINNED_TAG — bump
# the tag and the digests together, or the install runs unverified with a warning.
# Set NVIM_SHA256 in the environment to supply your own for another version.
NVIM_PINNED_TAG="v0.12.5"
NVIM_PINNED_SHA256_X86_64="bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875"
NVIM_PINNED_SHA256_ARM64="1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725"

# nvim-treesitter is on the `main` branch, which compiles parsers with the
# tree-sitter CLI rather than shipping them. This pin is the version that branch
# is known to work with here.
TREE_SITTER_VERSION="${TREE_SITTER_VERSION:-0.26.8}"

NVIM_PREFIX="/usr/local"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nvim-config"
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NOTES=()

REPLACE_DISTRO=0
SKIP_BOOTSTRAP="${NVIM_SKIP_BOOTSTRAP:-0}"
SKIP_NVIM="${NVIM_SKIP_NEOVIM:-0}"
FORCE=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die() {
	printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2
	exit 1
}
note() { NOTES+=("$*"); }

usage() {
	cat <<'EOF'
Usage: install.sh [options]

  --replace-distro       Remove a neovim installed by the system package manager,
                         THROUGH that package manager (apt-get remove neovim, …),
                         so /usr/local/bin/nvim is the only one left. Opt-in on
                         purpose: without it the packaged neovim is left exactly
                         where it is and you are told which one PATH resolves.
  --nvim-version VER     Install this neovim tag instead of the pinned one
                         (e.g. v0.12.4). The recorded checksum only covers the
                         pinned tag, so another version installs unverified
                         unless you also set NVIM_SHA256.
  --skip-neovim          Do not touch neovim; only install the config.
  --skip-bootstrap       Do not run the headless :Lazy sync / parser install.
  --force                Replace ~/.config/nvim even when it is a symlink
                         (e.g. managed by linux-devops-tools). Backed up first.
  -h, --help             This text.

Environment equivalents: NVIM_VERSION, NVIM_SHA256, TREE_SITTER_VERSION,
NVIM_SKIP_NEOVIM=1, NVIM_SKIP_BOOTSTRAP=1.

Piping from curl? Pass flags after `--`:
  curl -sSL .../install.sh | bash -s -- --replace-distro
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--replace-distro) REPLACE_DISTRO=1 ;;
	--nvim-version)
		[ $# -ge 2 ] || die "--nvim-version needs a value"
		NVIM_VERSION="$2"
		shift
		;;
	--nvim-version=*) NVIM_VERSION="${1#*=}" ;;
	--skip-neovim) SKIP_NVIM=1 ;;
	--skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
	--force) FORCE=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

have() { command -v "$1" >/dev/null 2>&1; }

# Root only where root is genuinely needed, and never assume sudo exists.
as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif have sudo; then
		sudo "$@"
	else
		return 127
	fi
}

# ---------------------------------------------------------------------------
# Exec-capable scratch
# ---------------------------------------------------------------------------
#
# This is the same mechanism as `devenv_execdir` in lib/common.sh of
# Ujstor/linux-devops-tools, deliberately mirrored rather than reinvented.
#
# A hardened host mounts /tmp `noexec` — the estate's own vm-hardening role makes
# exactly that change, so it is true of every hardened host in the fleet — and
# then nothing written into a `mktemp -d` can be executed. Two steps below are
# exactly that shape, and both were broken on such a host:
#
#   * sh.rustup.rs downloads rustup-init into `mktemp -d`, chmod u+x's it and
#     runs it —
#         error: Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
#         (likely because of mounting /tmp as noexec)
#   * `cargo install` builds under the temp dir and executes the build scripts it
#     compiles there —
#         could not execute process `/tmp/cargo-installXXXXXX/release/build/
#           prettyplease-<hash>/build-script-build` (never executed)
#         Caused by: Permission denied (os error 13)
#
# Either one costs this script the tree-sitter CLI, and with it every parser.
#
# The answer is PROBED, never assumed. `mount` output and /proc/mounts both lie
# here — a bind mount re-flags a subtree, an overlay's upper layer is not the
# mount you can see, a user namespace shows you the host's table — and the only
# question that matters is "does execve() work on a file I just wrote here", so
# that is the question this asks.
#
# Candidates, in order; the first that passes the probe wins:
#
#     $TMPDIR -> /tmp -> $XDG_RUNTIME_DIR -> $XDG_CACHE_HOME/nvim-config/exec
#             -> $HOME/.cache/nvim-config/exec
#
# The last two are under $HOME on purpose: they are the fallback for the host
# where every shared temp filesystem is noexec. The EXIT trap removes whatever
# was created, including a parent this script had to make.

EXEC_ROOT=""
EXEC_DIR=""

# NOTE on shape: exec_root_init/exec_dir_alloc ASSIGN GLOBALS; they do not print a
# path for a caller to capture. That is deliberate. `work="$(exec_dir)"` would run
# the probe inside a command substitution, i.e. a subshell, and the subshell's
# `EXEC_ROOT=...` dies with it — so the parent's cleanup trap would find EXEC_ROOT
# still empty and leave the whole scratch tree behind, and a second caller would
# re-probe and leak another one. lib/common.sh in linux-devops-tools solves the
# same problem with a stamp file because its callers span separate processes;
# inside one script, a global is the honest fix.

# exec_probe DIR — 0 when a file created in DIR can be made executable AND run.
# The probe script exits 41, and ONLY 41 is accepted: 126 is "found but not
# executable" (which is exactly what noexec looks like) and 127 is "no
# interpreter" — neither proves the kernel ran anything.
# PRECONDITION: DIR is one this script just created itself, mode 0700 (mktemp -d).
# The probe's file name is predictable, and a predictable name in a
# world-writable directory such as /tmp is a symlink-clobber waiting to happen;
# probing the mktemp'd directory and never /tmp itself is what avoids that.
exec_probe() {
	local dir="${1-}" probe rc=0
	[ -n "$dir" ] && [ -d "$dir" ] || return 1
	probe="$dir/.nvim-config-execprobe.$$"
	{ printf '#!/bin/sh\nexit 41\n' >"$probe"; } 2>/dev/null || {
		rm -f -- "$probe" 2>/dev/null || :
		return 1
	}
	chmod 0700 -- "$probe" 2>/dev/null || {
		rm -f -- "$probe" 2>/dev/null || :
		return 1
	}
	"$probe" >/dev/null 2>&1 || rc=$?
	rm -f -- "$probe" 2>/dev/null || :
	[ "$rc" -eq 41 ]
}

# exec_root_init — sets $EXEC_ROOT to the per-run exec-capable root, probing for
# it on first use. Returns 1, having said why, when nothing on this host executes.
# Says out loud, ONCE, when it had to fall off /tmp. A SILENT fallback is exactly
# how "/tmp is noexec on every hardened host in the fleet" stays invisible: the
# install simply fails later and nothing names the reason.
exec_root_init() {
	[ -z "$EXEC_ROOT" ] || return 0
	# An array, not a " $tried " string: a `case " $tried " in *" $c "*` test reads
	# a path containing a space as two candidates and would skip a good directory
	# because an unrelated one shared a word with it.
	local cand root="" s dup
	local -a tried=()
	for cand in "${TMPDIR:-}" /tmp "${XDG_RUNTIME_DIR:-}" \
		"${XDG_CACHE_HOME:-$HOME/.cache}/nvim-config/exec" "$HOME/.cache/nvim-config/exec"; do
		[ -n "$cand" ] || continue
		cand="${cand%/}"
		[ -n "$cand" ] || continue
		dup=0
		if [ ${#tried[@]} -gt 0 ]; then
			for s in "${tried[@]}"; do
				[ "$s" = "$cand" ] && dup=1
			done
		fi
		[ "$dup" = 0 ] || continue
		tried+=("$cand")
		# Only the two $HOME fallbacks are ours to create; a missing $TMPDIR or
		# $XDG_RUNTIME_DIR means "not available here", not "make one".
		case "$cand" in
		*/exec) mkdir -p -- "$cand" 2>/dev/null || continue ;;
		esac
		root="$(mktemp -d "$cand/nvim-config-exec.XXXXXXXX" 2>/dev/null)" || {
			root=""
			continue
		}
		# Probe the directory actually handed out, not its parent.
		exec_probe "$root" && break
		rm -rf -- "$root"
		root=""
	done
	if [ -z "$root" ]; then
		warn "no exec-capable scratch directory is available on this host."
		warn "  tried: ${tried[*]:-(nothing)}"
		warn "  each one is missing, not writable, or on a filesystem mounted noexec."
		warn "  Point TMPDIR at a directory that permits execution and re-run."
		return 1
	fi
	EXEC_ROOT="$root"
	case "${root%/*}" in
	"${TMPDIR:-/tmp}" | /tmp) : ;;
	*)
		log "scratch: /tmp here does not permit execution (mounted noexec?)"
		info "downloaded installers will be run from $root instead"
		;;
	esac
	return 0
}

# exec_dir_alloc — sets $EXEC_DIR to a fresh empty directory that is writable AND
# executes. For a downloaded artefact that has to RUN. Everything that is only
# written, read or unpacked (`tar`, `cp`, `install`, `git clone`) works fine on
# noexec and uses a plain mktemp -d.
exec_dir_alloc() {
	exec_root_init || return 1
	EXEC_DIR="$(mktemp -d "$EXEC_ROOT/x.XXXXXXXX")" || return 1
}

CLONE_DIR=""
STAGE_DIR=""
cleanup() {
	# `return 0` is load-bearing: under `set -e` a trap whose last command
	# returns non-zero becomes the SCRIPT's exit status, so a clean install would
	# still report failure and break any `&&` chain or CI gate.
	[ -n "$CLONE_DIR" ] && rm -rf -- "$CLONE_DIR"
	[ -n "$STAGE_DIR" ] && rm -rf -- "$STAGE_DIR"
	if [ -n "$EXEC_ROOT" ]; then
		case "$EXEC_ROOT" in
		*/nvim-config-exec.*) rm -rf -- "$EXEC_ROOT" ;;
		esac
		# The $HOME fallbacks had to create their own parent; take it back when it
		# is empty. rmdir refuses a non-empty directory, which is the guard wanted.
		case "$EXEC_ROOT" in
		*/exec/nvim-config-exec.*) rmdir -- "${EXEC_ROOT%/*}" 2>/dev/null || : ;;
		esac
	fi
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
PKG=""
detect_pkg() {
	local p
	for p in apt-get dnf yum pacman zypper apk; do
		have "$p" && {
			PKG="$p"
			return 0
		}
	done
	return 1
}

APT_UPDATED=0
pkg_install() { # pkg_install <debian-names...>  (best effort elsewhere)
	[ $# -gt 0 ] || return 0
	case "$PKG" in
	apt-get)
		if [ "$APT_UPDATED" -eq 0 ]; then
			as_root apt-get update -qq || return 1
			APT_UPDATED=1
		fi
		as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
		;;
	dnf | yum) as_root "$PKG" install -y "$@" ;;
	pacman) as_root pacman -S --needed --noconfirm "$@" ;;
	zypper) as_root zypper --non-interactive install "$@" ;;
	apk) as_root apk add --no-cache "$@" ;;
	*) return 1 ;;
	esac
}

# ensure_runtime_packages — what the CONFIG needs at runtime, nothing more.
# The compiler/rust build dependencies are NOT here: they are pulled in only when
# tree-sitter actually has to be built (see ensure_tree_sitter), so a re-run on a
# box that already has the CLI touches the package manager not at all.
ensure_runtime_packages() {
	local missing=()
	have git || missing+=(git)
	have curl || missing+=(curl)
	have rg || missing+=(ripgrep)
	have unzip || missing+=(unzip)
	have tar || missing+=(tar)
	# fd is `fd-find` on Debian/Ubuntu, `fd` elsewhere.
	if ! have fd && ! have fdfind; then
		case "$PKG" in
		apt-get) missing+=(fd-find) ;;
		*) missing+=(fd) ;;
		esac
	fi
	[ ${#missing[@]} -gt 0 ] || {
		info "prerequisites: all present"
		return 0
	}
	log "installing prerequisites: ${missing[*]}"
	pkg_install "${missing[@]}" || warn "could not install: ${missing[*]}"
	have git || die "git is required and could not be installed"
	have curl || die "curl is required and could not be installed"
	return 0
}

# ensure_build_packages — the toolchain `cargo install tree-sitter-cli` needs.
#
# libclang is NOT optional and is the one people drop. tree-sitter-cli 0.26 pulls
# in rquickjs-sys, whose build script runs bindgen, and bindgen dlopen()s
# libclang at BUILD time. Without it a five-minute build dies at the last crate:
#     Unable to find libclang: "couldn't find any valid shared libraries matching:
#     ['libclang.so', …], set the `LIBCLANG_PATH` environment variable"
# Observed for tree-sitter-cli 0.26.8 with only build-essential installed.
#
# Memoised: it is called both before the rustup bootstrap and again immediately
# before the build, so a box with cc but no libclang-dev is still covered, while
# a single run never hits the package manager twice.
BUILD_PKGS_DONE=0
ensure_build_packages() {
	[ "$BUILD_PKGS_DONE" = 1 ] && return 0
	BUILD_PKGS_DONE=1
	log "installing the toolchain needed to build the tree-sitter CLI"
	case "$PKG" in
	apt-get) pkg_install build-essential make pkg-config libssl-dev clang libclang-dev ;;
	dnf | yum) pkg_install gcc gcc-c++ make pkgconf-pkg-config openssl-devel clang clang-devel ;;
	pacman) pkg_install base-devel pkg-config openssl clang ;;
	zypper) pkg_install gcc gcc-c++ make pkg-config libopenssl-devel clang clang-devel ;;
	apk) pkg_install build-base pkgconf openssl-dev clang-dev ;;
	*) warn "unknown package manager: install a C toolchain, make, pkg-config and libclang yourself" ;;
	esac || warn "could not install every build dependency; the cargo build may fail"
	return 0
}

# ---------------------------------------------------------------------------
# rust + tree-sitter CLI
# ---------------------------------------------------------------------------
tree_sitter_version_of() { "$1" --version 2>/dev/null | awk '{print $2}'; }

install_rustup() {
	local work
	log "installing the rust toolchain (no cargo found)"

	# THE noexec FIX. sh.rustup.rs downloads rustup-init into `mktemp -d`,
	# chmod u+x's it and execs it; on a host with /tmp noexec that is
	#     error: Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
	#     (likely because of mounting /tmp as noexec)
	# Fetching the script into an exec-capable directory AND pointing the
	# installer's own TMPDIR at it is what moves that mktemp onto a filesystem
	# that executes. This is the same treatment lib/net.sh's sh_installer_run
	# gives every vendor installer in Ujstor/linux-devops-tools.
	exec_dir_alloc || {
		warn "cannot bootstrap rustup without an exec-capable directory"
		return 1
	}
	work="$EXEC_DIR"
	curl -fsSL --proto '=https' --tlsv1.2 --retry 3 https://sh.rustup.rs -o "$work/rustup-init.sh" || {
		warn "could not download the rustup installer"
		return 1
	}

	# Unpinned on purpose, and said out loud rather than hidden: rust-lang
	# publishes rustup-init through this redirector and signs the release
	# artefacts it fetches, not the shell wrapper, so there is no stable
	# per-release digest of THIS script to pin.
	info "running the rustup installer (unpinned: upstream publishes no digest for it)"

	# --no-modify-path: rustup would otherwise append a source line to ~/.bashrc,
	# ~/.profile and ~/.zshenv. This script puts cargo on PATH for its own run
	# below, and ~/.cargo/env is sourced for interactive shells by whatever owns
	# your dotfiles — not by an installer editing them behind your back.
	# --profile minimal: rustc + cargo + rust-std. rust-docs alone is ~200 MB.
	env TMPDIR="$work" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="$CARGO_HOME_DIR" \
		sh "$work/rustup-init.sh" -y --no-modify-path --profile minimal \
		--default-toolchain "${RUST_TOOLCHAIN:-stable}" || {
		warn "rustup could not be installed"
		return 1
	}

	PATH="$CARGO_HOME_DIR/bin:$PATH"
	export PATH
	hash -r 2>/dev/null || true
	note "rustup was installed with --no-modify-path; add \"$CARGO_HOME_DIR/bin\" to PATH (or source $CARGO_HOME_DIR/env) in your shell rc to use cargo interactively."
}

ensure_tree_sitter() {
	# Put a cargo-installed CLI on PATH before deciding anything: on a box where
	# rustup ran with --no-modify-path, ~/.cargo/bin is not on a non-interactive
	# PATH and the check below would rebuild a CLI that is already there.
	[ -d "$CARGO_HOME_DIR/bin" ] && case ":$PATH:" in
	*":$CARGO_HOME_DIR/bin:"*) : ;;
	*) PATH="$CARGO_HOME_DIR/bin:$PATH" ;;
	esac
	export PATH

	local cur=""
	if have tree-sitter; then
		cur="$(tree_sitter_version_of tree-sitter)"
		if [ "$cur" = "$TREE_SITTER_VERSION" ]; then
			log "tree-sitter: already $cur at $(command -v tree-sitter)"
			return 0
		fi
		# A version gate, not just a presence gate. The previous script only asked
		# `command -v tree-sitter`, so a distro CLI three minor versions behind the
		# one nvim-treesitter's main branch needs was silently accepted, and the
		# parser build failed much later with something unrelated-looking.
		info "tree-sitter ${cur:-unknown} is installed; this config is pinned to $TREE_SITTER_VERSION"
	fi

	if ! have cargo; then
		ensure_build_packages
		install_rustup || :
	fi
	# From here on nothing aborts the run. Without the tree-sitter CLI you get the
	# config with no parsers — degraded, but yours — and a note saying what to fix.
	# `die` here would mean a transient cargo failure also costs you the config
	# install, which is the part you actually came for.
	have cargo || {
		warn "cargo is not available; cannot build the tree-sitter CLI"
		note "no tree-sitter CLI: treesitter parsers will not compile. Install rust, then re-run this script."
		return 0
	}
	# Again (memoised, so it is a no-op when the branch above already ran it): a
	# box that arrives here with cargo already installed has never been through
	# ensure_build_packages, and `have cc` is not enough — libclang is what the
	# build actually dies without.
	ensure_build_packages

	log "building the tree-sitter CLI $TREE_SITTER_VERSION with cargo (a few minutes)"
	# THE SECOND noexec VECTOR, and the one that is easy to miss. `cargo install`
	# puts its build directory under the platform temp dir ($TMPDIR, else /tmp) and
	# then EXECUTES the build scripts it compiles there, so on a noexec /tmp the
	# build dies part-way through:
	#     could not execute process `/tmp/cargo-installXXXXXX/release/build/
	#       prettyplease-<hash>/build-script-build` (never executed)
	#     Caused by: Permission denied (os error 13)
	# Observed on cargo 1.98.1 with /tmp mounted noexec. It is version-dependent —
	# cargo 1.96.1 does NOT use the temp dir for this and installs fine with
	# TMPDIR=/nonexistent — which is precisely why it is handled here rather than
	# reasoned about: the same script meets both cargos.
	# Same single mechanism as the rustup bootstrap above, not a second one.
	exec_dir_alloc || {
		warn "no exec-capable scratch directory; cannot build the tree-sitter CLI"
		note "no tree-sitter CLI: treesitter parsers will not compile. Point TMPDIR at a directory that permits execution and re-run."
		return 0
	}
	env TMPDIR="$EXEC_DIR" cargo install --locked tree-sitter-cli --version "$TREE_SITTER_VERSION" || {
		warn "could not build the tree-sitter CLI $TREE_SITTER_VERSION"
		note "tree-sitter CLI build failed: treesitter parsers will not compile. Re-run this script, or: cargo install --locked tree-sitter-cli --version $TREE_SITTER_VERSION"
		return 0
	}
	hash -r 2>/dev/null || true

	# A system-wide handle so `:TSInstall` works in an interactive nvim whose PATH
	# does not carry ~/.cargo/bin. It points at a binary inside $HOME, which is
	# worth knowing: anyone who can write $CARGO_HOME/bin decides what
	# /usr/local/bin/tree-sitter runs. Only created when nothing else answers.
	if [ ! -e "$NVIM_PREFIX/bin/tree-sitter" ] && [ -x "$CARGO_HOME_DIR/bin/tree-sitter" ]; then
		if as_root ln -s "$CARGO_HOME_DIR/bin/tree-sitter" "$NVIM_PREFIX/bin/tree-sitter" 2>/dev/null; then
			note "$NVIM_PREFIX/bin/tree-sitter is a symlink into $CARGO_HOME_DIR/bin (a user-owned path)."
		else
			info "could not create $NVIM_PREFIX/bin/tree-sitter (no root?); PATH will have to carry $CARGO_HOME_DIR/bin"
		fi
	fi
	log "tree-sitter: $(tree_sitter_version_of tree-sitter) at $(command -v tree-sitter)"
}

# ---------------------------------------------------------------------------
# neovim
# ---------------------------------------------------------------------------
NVIM_ARCH=""
detect_arch() {
	[ "$(uname -s)" = "Linux" ] || die "this installer only handles Linux (uname -s says $(uname -s))"
	case "$(uname -m)" in
	x86_64 | amd64) NVIM_ARCH="x86_64" ;;
	aarch64 | arm64) NVIM_ARCH="arm64" ;;
	# The previous script hardcoded the x86_64 asset, so on arm64 it downloaded
	# and installed a binary that could not run.
	*) die "no neovim release build for $(uname -m); install neovim yourself and re-run with --skip-neovim" ;;
	esac
}

nvim_expected_sha() {
	if [ -n "${NVIM_SHA256:-}" ]; then
		printf '%s\n' "$NVIM_SHA256"
		return 0
	fi
	[ "$NVIM_VERSION" = "$NVIM_PINNED_TAG" ] || return 1
	case "$NVIM_ARCH" in
	x86_64) printf '%s\n' "$NVIM_PINNED_SHA256_X86_64" ;;
	arm64) printf '%s\n' "$NVIM_PINNED_SHA256_ARM64" ;;
	*) return 1 ;;
	esac
}

nvim_version_of() { "$1" --version 2>/dev/null | awk 'NR==1 {sub(/^v/,"",$2); print $2; exit}'; }

# report_nvim_on_path — which nvim actually wins, and what an old install left.
report_nvim_on_path() {
	local winner
	winner="$(command -v nvim 2>/dev/null || true)"
	[ -n "$winner" ] || return 0
	if [ "$winner" != "$NVIM_PREFIX/bin/nvim" ] && [ -x "$NVIM_PREFIX/bin/nvim" ]; then
		note "PATH resolves nvim to $winner ($(nvim_version_of "$winner")), not the $(nvim_version_of "$NVIM_PREFIX/bin/nvim") in $NVIM_PREFIX/bin. Put $NVIM_PREFIX/bin ahead of it, or re-run with --replace-distro."
	fi
	# Leftover from the old destructive install path: this script used to
	# `rm -rf /usr/bin/nvim` and symlink its own build over it, so dpkg/rpm now
	# disagrees with what is on disk.
	if [ -L /usr/bin/nvim ] && [ "$(readlink -f /usr/bin/nvim 2>/dev/null)" = "$NVIM_PREFIX/bin/nvim" ]; then
		note "/usr/bin/nvim is a symlink to $NVIM_PREFIX/bin/nvim — an earlier version of this script deleted the packaged binary. To restore it: sudo apt-get install --reinstall neovim"
	fi
}

# package_owning PATH — prints "<manager>:<package>" when PATH is owned by the
# system package manager, nothing when it is not.
package_owning() {
	local p="$1" owner=""
	if have dpkg; then
		owner="$(dpkg -S "$p" 2>/dev/null | head -n1 | cut -d: -f1)" || owner=""
		[ -n "$owner" ] && {
			printf 'dpkg:%s\n' "$owner"
			return 0
		}
	fi
	if have rpm; then
		owner="$(rpm -qf "$p" 2>/dev/null)" || owner=""
		case "$owner" in "" | *"not owned"*) owner="" ;; esac
		[ -n "$owner" ] && {
			printf 'rpm:%s\n' "$owner"
			return 0
		}
	fi
	if have pacman; then
		owner="$(pacman -Qoq "$p" 2>/dev/null)" || owner=""
		[ -n "$owner" ] && {
			printf 'pacman:%s\n' "$owner"
			return 0
		}
	fi
	return 1
}

# replace_distro_nvim — the ONLY path that removes an existing neovim, and it is
# reached only from --replace-distro.
#
# What the previous version of this script did unconditionally, on every run,
# with no flag and no warning:
#     rm -rf /usr/local/bin/nvim /usr/bin/nvim /usr/local/share/nvim /usr/share/nvim
# /usr/bin/nvim and /usr/share/nvim are dpkg-owned on every Debian/Ubuntu box, so
# that deleted packaged files behind the package manager's back: dpkg still
# believed neovim was installed, `apt-get install neovim` became a no-op, and
# anything depending on the package was quietly broken.
replace_distro_nvim() {
	local p owner mgr pkg removed=0
	for p in /usr/bin/nvim /usr/share/nvim; do
		[ -e "$p" ] || continue
		if owner="$(package_owning "$p")"; then
			mgr="${owner%%:*}"
			pkg="${owner#*:}"
			log "$p belongs to the package '$pkg' ($mgr) — removing it through the package manager"
			case "$mgr" in
			dpkg) as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$pkg" || warn "apt-get remove $pkg failed" ;;
			rpm) as_root "${PKG:-dnf}" remove -y "$pkg" || warn "removing $pkg failed" ;;
			pacman) as_root pacman -Rns --noconfirm "$pkg" || warn "pacman -Rns $pkg failed" ;;
			esac
			removed=1
		else
			warn "$p is owned by no package."
			warn "  It was most likely left by an earlier version of this script. Not deleting it:"
			warn "  remove it yourself if you are sure — sudo rm -rf $p"
			note "$p exists, is owned by no package, and was left in place."
		fi
	done
	[ "$removed" = 1 ] || info "--replace-distro: nothing packaged to remove"
	hash -r 2>/dev/null || true
}

install_neovim() {
	detect_arch
	local asset url want cur sha dl
	asset="nvim-linux-${NVIM_ARCH}.tar.gz"
	url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/${asset}"
	want="${NVIM_VERSION#v}"

	if [ -x "$NVIM_PREFIX/bin/nvim" ]; then
		cur="$(nvim_version_of "$NVIM_PREFIX/bin/nvim")"
		if [ "$cur" = "$want" ]; then
			log "neovim: already $cur at $NVIM_PREFIX/bin/nvim"
			return 0
		fi
		info "neovim ${cur:-unknown} -> $want"
	fi

	mkdir -p -- "$CACHE_DIR/dl"
	dl="$CACHE_DIR/dl/${NVIM_VERSION}-${asset}"
	if [ ! -s "$dl" ]; then
		log "downloading neovim $NVIM_VERSION ($asset)"
		curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dl.part" "$url" || {
			rm -f -- "$dl.part"
			die "could not download $url"
		}
		mv -f -- "$dl.part" "$dl"
	else
		info "using the cached $dl"
	fi

	if sha="$(nvim_expected_sha)"; then
		local got
		got="$(sha256sum "$dl" | awk '{print $1}')"
		if [ "${got,,}" != "${sha,,}" ]; then
			rm -f -- "$dl"
			die "checksum mismatch for $asset — expected $sha, got $got"
		fi
		info "sha256 ok (recorded by this repo for $NVIM_PINNED_TAG; upstream publishes none)"
	else
		warn "installing neovim $NVIM_VERSION WITHOUT a checksum: neovim publishes no checksum asset, and this repo only records one for $NVIM_PINNED_TAG. Source: $url"
	fi

	# Extract to a staging dir and check the shape BEFORE anything under
	# /usr/local is touched, so a truncated or wrong-shaped archive cannot leave a
	# half-replaced install behind. Extraction needs no exec permission, so this
	# stays on a plain mktemp -d even where /tmp is noexec.
	STAGE_DIR="$(mktemp -d)"
	tar -xzf "$dl" -C "$STAGE_DIR" || die "could not unpack $dl"
	local src="$STAGE_DIR/nvim-linux-${NVIM_ARCH}"
	# `-f`, NOT `-x`. `test -x` calls access(X_OK), which is itself noexec-aware:
	# on a host with /tmp mounted noexec it answers "no" for a perfectly good
	# binary that simply happens to be sitting on that filesystem, and this check
	# would reject every download. The mode bits survive the copy either way —
	# noexec is a property of the mount, not of the inode — so the binary is
	# executable once it reaches /usr/local.
	[ -f "$src/bin/nvim" ] || die "$asset does not contain nvim-linux-${NVIM_ARCH}/bin/nvim"

	# Replace the two subtrees that are exclusively neovim's, so runtime files
	# dropped by upstream between versions do not linger. Both are under
	# /usr/local, which no package manager owns, and share/nvim/site — where a
	# sysadmin's own runtime files would live — is deliberately left alone.
	log "installing neovim $want into $NVIM_PREFIX"
	as_root rm -rf -- "$NVIM_PREFIX/share/nvim/runtime" "$NVIM_PREFIX/lib/nvim/parser" ||
		die "could not clear the previous neovim runtime (no root?)"
	as_root cp -a -- "$src/." "$NVIM_PREFIX/" || die "could not install into $NVIM_PREFIX"
	rm -rf -- "$STAGE_DIR"
	STAGE_DIR=""
	hash -r 2>/dev/null || true
	log "neovim: $(nvim_version_of "$NVIM_PREFIX/bin/nvim") at $NVIM_PREFIX/bin/nvim"
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
SRC_DIR=""
resolve_payload() {
	local here="${BASH_SOURCE[0]:-}"
	if [ -n "$here" ] && [ -f "$here" ]; then
		here="$(cd "$(dirname "$here")" && pwd)"
		if [ -f "$here/init.lua" ] && [ -d "$here/lua" ]; then
			SRC_DIR="$here"
			log "config: using this checkout — $SRC_DIR"
			return
		fi
	fi
	CLONE_DIR="$(mktemp -d)"
	log "config: fetching $REPO_URL ($REPO_BRANCH)"
	git clone -q --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR/repo" ||
		die "could not clone $REPO_URL"
	SRC_DIR="$CLONE_DIR/repo"
}

# config_is_current SRC DST — 0 when DST already holds exactly SRC's payload.
# lazy-lock.json is the one file under ~/.config/nvim that is state rather than
# repo content (it is .gitignore'd), so it is excluded from the comparison and
# carried across a replacement below.
config_is_current() {
	have diff || return 1
	diff -rq --exclude=.git --exclude=.github --exclude=lazy-lock.json \
		-- "$1" "$2" >/dev/null 2>&1
}

install_config() {
	local dst="$CONFIG_DIR" bak lock=""

	if [ -L "$dst" ]; then
		# linux-devops-tools manages ~/.config/nvim as a symlink to its own
		# checkout of this repo. The previous script's `rm -rf ~/.config/nvim`
		# silently severed that and replaced it with a detached copy, so the
		# managed checkout stopped being what nvim read.
		if [ "$FORCE" != "1" ]; then
			warn "$dst is a symlink -> $(readlink "$dst")"
			warn "  left alone; something else manages this config. Update it there,"
			warn "  or re-run with --force to replace it."
			note "$dst was NOT updated (symlink; use --force)."
			return 0
		fi
		bak="$dst.symlink.bak.$STAMP"
		cp -P -- "$dst" "$bak"
		info "backed up the symlink $dst -> $bak"
		rm -f -- "$dst"
	elif [ -d "$dst" ]; then
		if config_is_current "$SRC_DIR" "$dst"; then
			log "config: $dst is already up to date"
			return 0
		fi
		[ -f "$dst/lazy-lock.json" ] && lock="$dst/lazy-lock.json"
		bak="$dst.bak.$STAMP"
		# Moved, never deleted. The previous script ran `rm -rf ~/.config/nvim`
		# with no backup and no prompt, so anyone who had edited their config in
		# place lost it to an install one-liner.
		mv -- "$dst" "$bak"
		log "backed up $dst -> $bak"
		[ -n "$lock" ] && lock="$bak/lazy-lock.json"
	elif [ -e "$dst" ]; then
		bak="$dst.bak.$STAMP"
		mv -- "$dst" "$bak"
		log "backed up the file $dst -> $bak"
	fi

	mkdir -p -- "$dst"
	cp -R -- "$SRC_DIR/." "$dst/"
	rm -rf -- "$dst/.git" "$dst/.github"
	# Keep the plugin pins from the config that was just replaced: lazy-lock.json
	# is not in the repo, and losing it turns a re-run into an unpinned upgrade of
	# every plugin.
	if [ -n "$lock" ] && [ -f "$lock" ] && [ ! -f "$dst/lazy-lock.json" ]; then
		cp -p -- "$lock" "$dst/lazy-lock.json"
		info "carried lazy-lock.json across from the backup"
	fi
	log "installed the config into $dst"
}

# ---------------------------------------------------------------------------
# headless bootstrap
# ---------------------------------------------------------------------------
bootstrap() {
	local nvim_bin
	nvim_bin="$(command -v nvim 2>/dev/null || true)"
	[ -n "$nvim_bin" ] || {
		warn "no nvim on PATH; skipping the headless bootstrap"
		note "run ':Lazy sync' and ':lua require(\"nvim-treesitter\").install(require(\"parsers\"))' yourself once nvim is on PATH."
		return 0
	}

	# nvim-treesitter's main branch compiles parsers under stdpath('cache')
	# (~/.cache/nvim), not under the temp dir — `cache_dir = stdpath('cache')` in
	# its install.lua — so the parser half does not need an exec-capable scratch.
	# TMPDIR is pointed at one anyway, for lazy.nvim's `build` steps: those are
	# arbitrary upstream commands, and at least one common shape (a cargo build)
	# is now known to execute out of the temp dir. Belt and braces, and free.
	# If nothing on this host executes, fall back to the inherited TMPDIR rather
	# than refuse to bootstrap — most plugins do not need it.
	local -a envv=()
	if exec_dir_alloc 2>/dev/null; then envv=(env "TMPDIR=$EXEC_DIR"); fi

	log "bootstrapping plugins (lazy.nvim sync)"
	# stdin closed: a headless nvim that hits a prompt with an attached terminal
	# blocks forever, which is how `curl | bash` installs hang.
	"${envv[@]}" "$nvim_bin" --headless "+Lazy! sync" +qa </dev/null >/dev/null 2>&1 ||
		note "':Lazy sync' did not finish cleanly; run it inside nvim."

	log "bootstrapping treesitter parsers (this can take a few minutes)"
	"${envv[@]}" "$nvim_bin" --headless \
		-c 'lua require("nvim-treesitter").install(require("parsers")):wait(600000)' +qa \
		</dev/null 2>&1 | tail -n 5 ||
		note "the treesitter parser install did not finish cleanly; run ':lua require(\"nvim-treesitter\").install(require(\"parsers\"))' inside nvim."
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
detect_pkg || warn "no known package manager found; skipping automatic installs"

log "checking prerequisites"
ensure_runtime_packages

if [ "$SKIP_NVIM" = "1" ]; then
	info "--skip-neovim: leaving neovim alone"
else
	[ "$REPLACE_DISTRO" = "1" ] && replace_distro_nvim
	install_neovim
	report_nvim_on_path
fi

ensure_tree_sitter

resolve_payload
install_config

if [ "$SKIP_BOOTSTRAP" = "1" ]; then
	info "--skip-bootstrap: not running the headless sync"
else
	bootstrap
fi

echo
if have nvim; then
	log "done — neovim $(nvim_version_of "$(command -v nvim)"), config at $CONFIG_DIR"
else
	log "done — config at $CONFIG_DIR"
fi
info "launch with: nvim"
if [ ${#NOTES[@]} -gt 0 ]; then
	echo
	warn "worth knowing:"
	for n in "${NOTES[@]}"; do printf '    - %s\n' "$n"; done
fi
