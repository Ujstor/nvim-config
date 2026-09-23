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
#      unzip, a C compiler — every treesitter parser is compiled on this host)
#   2. makes sure the pinned tree-sitter CLI is present — building it with cargo,
#      and bootstrapping rustup first when there is no cargo — and puts a
#      root-owned copy of it in /usr/local/bin
#   3. installs the PINNED neovim release into /usr/local
#   4. backs up ~/.config/nvim, then installs this repo there
#   5. installs the plugins (at the lazy-lock.json pins when there is one) and
#      the treesitter parsers headlessly, so the first launch is clean
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
  --skip-bootstrap       Do not run the headless plugin / parser install.
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
# Candidates, in order; the first that passes BOTH probes wins:
#
#     $TMPDIR -> /tmp -> $XDG_CACHE_HOME/nvim-config/exec
#             -> $HOME/.cache/nvim-config/exec -> $XDG_RUNTIME_DIR
#
# The two $HOME entries sit AHEAD of $XDG_RUNTIME_DIR on purpose, and that
# ordering is the whole point of the second probe. A runtime dir passes the exec
# probe but is a tmpfs sized against RAM (10% of it under stock systemd), so a
# cargo build there both runs out of room and eats the memory the compiler
# needs. On a 1 GiB guest whose /run/user/1000 is 94 MiB, falling back to it
# turned a noexec /tmp into an OOM-killed rustc:
#     error: could not compile `regex-syntax` (lib)
#     Caused by: process didn't exit successfully: `rustc ...` (signal: 9, SIGKILL)
# $HOME is disk-backed and is the honest place for a multi-hundred-MiB build
# tree; $XDG_RUNTIME_DIR stays last as a genuine last resort, for the host where
# $HOME is mounted noexec too.
#
# Hence exec_space_ok: a candidate that executes but is too cramped is
# remembered and used ONLY if nothing roomier answers, and it says so. Silently
# building in 94 MiB of RAM is the failure this avoids. The EXIT trap removes
# whatever was created, including a parent this script had to make.

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

# Free space the tree-sitter build actually needs. cargo's target tree for
# tree-sitter-cli 0.26 runs to a few hundred MiB; rustup-init wants far less.
# 1 GiB is a floor that separates a real scratch filesystem from a runtime
# tmpfs — it is a preference between candidates, not a reservation.
EXEC_MIN_KIB=1048576

# exec_space_ok DIR — 0 when DIR's filesystem has at least $EXEC_MIN_KIB free.
# `df -Pk` is the portable spelling; -P keeps one line per filesystem even when
# the device name is long. An unreadable df counts as roomy: this ranks
# candidates, and it must never be the thing that strands a run with no scratch.
exec_space_ok() {
	local dir="${1-}" avail
	avail="$(df -Pk -- "$dir" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
	[ -n "$avail" ] || return 0
	[ "$avail" -ge "$EXEC_MIN_KIB" ]
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
	local cand root="" cramped="" s dup
	local -a tried=()
	for cand in "${TMPDIR:-}" /tmp \
		"${XDG_CACHE_HOME:-$HOME/.cache}/nvim-config/exec" "$HOME/.cache/nvim-config/exec" \
		"${XDG_RUNTIME_DIR:-}"; do
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
		if ! exec_probe "$root"; then
			rm -rf -- "$root"
			root=""
			continue
		fi
		# It executes. Is there room to build in it? A cramped root is better
		# than no root, but only after every roomier candidate has been tried,
		# so hold the first one aside and keep looking.
		exec_space_ok "$root" && break
		if [ -n "$cramped" ]; then
			rm -rf -- "$root"
		else
			cramped="$root"
		fi
		root=""
	done
	if [ -z "$root" ] && [ -n "$cramped" ]; then
		root="$cramped"
		cramped=""
		warn "scratch $root has under $((EXEC_MIN_KIB / 1024)) MiB free."
		warn "  it is the only exec-capable directory on this host; the cargo build may"
		warn "  run out of room, and if it is a tmpfs the build competes with itself for RAM."
	fi
	if [ -n "$cramped" ]; then
		rm -rf -- "$cramped"
		cramped=""
	fi
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
cleanup() {
	# `return 0` is load-bearing: under `set -e` a trap whose last command
	# returns non-zero becomes the SCRIPT's exit status, so a clean install would
	# still report failure and break any `&&` chain or CI gate.
	[ -n "$CLONE_DIR" ] && rm -rf -- "$CLONE_DIR"
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

# ensure_runtime_packages — what the CONFIG needs at runtime, nothing more. That
# includes a C compiler, because parsers are compiled at runtime. The rest of the
# toolchain (make, pkg-config, openssl and libclang headers) is NOT here: it is
# pulled in only when tree-sitter actually has to be built (see
# ensure_tree_sitter), so a re-run on a box that already has everything touches
# the package manager not at all.
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
	# A C compiler is a RUNTIME need of this config, not only a build one:
	# nvim-treesitter's main branch compiles every parser on this host with
	# `tree-sitter build`. Without one every parser failed to build, and the run
	# still ended in "done".
	if ! have cc; then
		case "$PKG" in
		apt-get) missing+=(build-essential) ;;
		dnf | yum | zypper) missing+=(gcc) ;;
		pacman) missing+=(base-devel) ;;
		apk) missing+=(build-base) ;;
		esac
	fi
	if [ ${#missing[@]} -gt 0 ]; then
		log "installing prerequisites: ${missing[*]}"
		pkg_install "${missing[@]}" || warn "could not install: ${missing[*]}"
	else
		info "prerequisites: all present"
	fi
	have git || die "git is required and could not be installed"
	have curl || die "curl is required and could not be installed"
	have cc || note "no C compiler: treesitter parsers cannot be built. Install gcc or clang, then run :TSInstall inside nvim."

	# clang as well where cc is gcc 12 (Debian 12's). Under the -Wall that
	# `tree-sitter build` passes, gcc 12 spent over 25 minutes and ~2 GB on the
	# gitcommit parser alone; clang builds the same file in 7 s, and the config
	# builds parsers with clang whenever it is installed. Asked only after the
	# install above, which is what put gcc on a fresh box.
	local ccv
	ccv="$(cc -dumpversion 2>/dev/null || :)"
	if [ "${ccv%%.*}" = 12 ] && ! have clang; then
		log "installing clang (gcc 12 takes 25+ minutes over some treesitter parsers)"
		pkg_install clang || warn "could not install clang; parsers will be built with gcc 12, slowly"
	fi
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
# tree_sitter_version_of BIN — BIN's version, or nothing. Never a failure: under
# `set -euo pipefail` a CLI on PATH that cannot run (upstream's release build
# needs glibc 2.39 and dies at load on bookworm) otherwise ended the whole run at
# the plain assignment capturing this, without a word.
tree_sitter_version_of() { "$1" --version 2>/dev/null | awk '{print $2}' || :; }

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
	install_tree_sitter_cli
	publish_tree_sitter
}

install_tree_sitter_cli() {
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
	log "tree-sitter: $(tree_sitter_version_of tree-sitter) at $(command -v tree-sitter)"
}

# publish_tree_sitter — a ROOT-OWNED copy of the pinned CLI at
# $NVIM_PREFIX/bin/tree-sitter, so `:TSInstall` works in an nvim whose PATH does
# not carry ~/.cargo/bin, root's included.
#
# A copy, never a link. This script used to create
#     /usr/local/bin/tree-sitter -> ~/.cargo/bin/tree-sitter
# and root's nvim runs that CLI without being asked: the config builds missing
# parsers at startup, and linux-devops-tools gives root the same config. The
# user who owned ~/.cargo/bin therefore decided what ran as root — swapping the
# link's target for a wrapper logged `tree-sitter build ran as uid=0` 35 times in
# one root session. A link, or a file root does not own, is replaced for that
# reason, on every run, including the ones that build nothing.
publish_tree_sitter() {
	local dest="$NVIM_PREFIX/bin/tree-sitter" src tmp why=""
	if [ -L "$dest" ]; then
		why="it is a symlink -> $(readlink -- "$dest")"
	elif [ -e "$dest" ] && [ "$(stat -c %u -- "$dest" 2>/dev/null || :)" != 0 ]; then
		why="root does not own it"
	elif [ "$(tree_sitter_version_of "$dest")" = "$TREE_SITTER_VERSION" ]; then
		return 0
	fi

	src="$(command -v tree-sitter 2>/dev/null || :)"
	if [ -z "$src" ] || [ "$(tree_sitter_version_of "$src")" != "$TREE_SITTER_VERSION" ]; then
		# Nothing pinned to put there; an unsafe handle is reported, not deleted,
		# since removing it takes the CLI away from whoever relies on it.
		if [ -n "$why" ]; then
			warn "$dest is unsafe: $why, and root's nvim runs it."
			note "$dest: $why. Root's nvim runs it; remove it (sudo rm $dest) or re-run this script once the tree-sitter CLI builds."
		fi
		return 0
	fi

	[ -z "$why" ] || warn "$dest: $why — replacing it with a root-owned copy"
	# Into a temporary name first, then renamed over: rename(2) replaces a symlink
	# rather than writing through it, and never leaves a half-written binary.
	tmp="$dest.new.$$"
	if as_root install -m 0755 -o root -g root -- "$src" "$tmp" 2>/dev/null &&
		as_root mv -f -- "$tmp" "$dest"; then
		info "root-owned tree-sitter $TREE_SITTER_VERSION at $dest"
		return 0
	fi
	as_root rm -f -- "$tmp" 2>/dev/null || :
	if [ -n "$why" ]; then
		warn "could not replace $dest (no root?) — root's nvim still runs it."
		note "$dest: $why. Root's nvim runs it; remove it (sudo rm $dest) or re-run this script with sudo available."
	else
		info "could not install $dest (no root?); PATH will have to carry $(dirname -- "$src")"
	fi
	return 0
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

# nvim_version_of BIN — as tree_sitter_version_of: the version or nothing, never
# a failure (a truncated or wrong-arch nvim exits 126 or 139 here).
nvim_version_of() { "$1" --version 2>/dev/null | awk 'NR==1 {sub(/^v/,"",$2); print $2; exit}' || :; }

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

# nvim_foreign — the first path of the neovim install in $NVIM_PREFIX that root
# does not own, or nothing. An earlier version of this script unpacked neovim
# into a user-owned staging directory and `sudo cp -a`'d that onto the prefix,
# and `cp -a` copies the staging directory's OWN owner and mode onto the target:
# the user who ran it came to own $NVIM_PREFIX itself, every directory neovim
# writes into, and the runtime that root's nvim loads — enough to swap
# /usr/local/sbin, first in sudo's secure_path, for their own. Run as root, the
# same copy handed all of it to uid 1001, the archive's `runner` owner.
nvim_foreign() {
	{
		find "$NVIM_PREFIX" "$NVIM_PREFIX/bin" "$NVIM_PREFIX/lib" "$NVIM_PREFIX/share" \
			-maxdepth 0 ! -uid 0 -print -quit 2>/dev/null || :
		find "$NVIM_PREFIX/bin/nvim" "$NVIM_PREFIX/lib/nvim" "$NVIM_PREFIX/share/nvim/runtime" \
			! -uid 0 -print -quit 2>/dev/null || :
	} | head -n 1
}

# reclaim_prefix_dirs LISTING — root takes back each directory of $NVIM_PREFIX
# the archive writes into, when someone else owns it. --no-overwrite-dir leaves
# an existing directory's owner alone, so where the old `cp -a` had handed
# $NVIM_PREFIX, bin, share, … to a user, that user would otherwise keep them.
# Directories root already owns (Debian's root:staff 2775 ones included) are
# not touched.
reclaim_prefix_dirs() {
	local -a dirs=() fix=()
	mapfile -t dirs < <(
		printf '%s\n' "$NVIM_PREFIX"
		sed -n 's|^nvim-linux-'"$NVIM_ARCH"'/\(.*[^/]\)/$|'"$NVIM_PREFIX"'/\1|p' <<<"$1"
	)
	mapfile -t fix < <(find "${dirs[@]}" -maxdepth 0 -type d ! -uid 0 -print 2>/dev/null || :)
	[ ${#fix[@]} -gt 0 ] || return 0
	log "giving ${#fix[@]} director(ies) under $NVIM_PREFIX back to root"
	if as_root chown root:root -- "${fix[@]}" && as_root chmod 0755 -- "${fix[@]}"; then
		note "root took back ${#fix[@]} director(ies) under $NVIM_PREFIX that an earlier version of this script had given away. Anything else there that root does not own is not this script's to judge: sudo find $NVIM_PREFIX -xdev ! -uid 0 -ls"
	else
		warn "could not give these back to root: ${fix[*]}"
	fi
}

install_neovim() {
	detect_arch
	local asset url want sha dl listing top cur="" foreign=""
	asset="nvim-linux-${NVIM_ARCH}.tar.gz"
	url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/${asset}"
	want="${NVIM_VERSION#v}"

	if [ -x "$NVIM_PREFIX/bin/nvim" ]; then
		cur="$(nvim_version_of "$NVIM_PREFIX/bin/nvim")"
		foreign="$(nvim_foreign)"
		if [ "$cur" = "$want" ] && [ -z "$foreign" ]; then
			log "neovim: already $cur at $NVIM_PREFIX/bin/nvim"
			return 0
		fi
		if [ -n "$foreign" ]; then
			warn "root does not own $foreign — reinstalling neovim so that it does"
		else
			info "neovim ${cur:-unknown} -> $want"
		fi
	fi

	# Everything below writes to $NVIM_PREFIX as root, so ask for root first. A
	# user without usable sudo still gets the config: this step used to die
	# half-way and take the config install down with it.
	if ! as_root true 2>/dev/null; then
		if [ "$cur" = "$want" ]; then
			warn "no usable sudo: cannot give $NVIM_PREFIX back to root"
		else
			warn "no usable sudo: neovim $want is NOT installed into $NVIM_PREFIX"
			note "neovim was not installed: it goes into $NVIM_PREFIX, which needs root, and sudo is missing, refused, or wanted a password with no terminal to ask on. Install neovim 0.12+ yourself, or re-run where sudo works (--skip-neovim skips this step)."
		fi
		[ -z "$foreign" ] || note "root does not own $foreign, and root runs what is there. As root: chown -R root:root $NVIM_PREFIX/share/nvim $NVIM_PREFIX/lib/nvim $NVIM_PREFIX/bin/nvim && chown root:root $NVIM_PREFIX $NVIM_PREFIX/bin $NVIM_PREFIX/lib $NVIM_PREFIX/share"
		return 0
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

	# The archive's shape, checked BEFORE anything under $NVIM_PREFIX is touched,
	# so a truncated or wrong-shaped archive cannot leave a half-replaced install:
	# the binary is where it belongs, and nothing lies outside the one top-level
	# directory that --strip-components removes. Read from the listing, not a
	# staged copy — there is no staged copy any more.
	top="nvim-linux-${NVIM_ARCH}/"
	listing="$(tar -tzf "$dl")" || die "could not read $dl"
	grep -qx "${top}bin/nvim" <<<"$listing" || die "$asset does not contain ${top}bin/nvim"
	if grep -qv "^${top}" <<<"$listing"; then
		die "$asset has entries outside ${top}; refusing to unpack it into $NVIM_PREFIX"
	fi

	# Replace the two subtrees that are exclusively neovim's, so runtime files
	# dropped by upstream between versions do not linger. Both are under
	# /usr/local, which no package manager owns, and share/nvim/site — where a
	# sysadmin's own runtime files would live — is deliberately left alone.
	log "installing neovim $want into $NVIM_PREFIX"
	as_root rm -rf -- "$NVIM_PREFIX/share/nvim/runtime" "$NVIM_PREFIX/lib/nvim/parser" ||
		die "could not clear the previous neovim runtime"
	# Unpacked BY ROOT, straight into the prefix, never staged somewhere the
	# invoking user owns and copied from there (nvim_foreign says what that did):
	#   --no-same-owner      root's tar otherwise restores the archive's owner,
	#                        uid 1001, on every file
	#   --no-overwrite-dir   an existing directory keeps its own owner and mode;
	#                        $NVIM_PREFIX, bin, share, … are not neovim's
	# Root's tar also takes the modes from the archive (0755/0644) rather than
	# from the umask, so a hardened umask 027 no longer locks every other user
	# out of /usr/local/bin.
	as_root tar -xzf "$dl" -C "$NVIM_PREFIX" --strip-components=1 --no-same-owner --no-overwrite-dir ||
		die "could not unpack $dl into $NVIM_PREFIX"
	reclaim_prefix_dirs "$listing"
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
# The headless parser install, as one `-c` command. Why each part is there:
#   * pcall + cquit: `:wait()` RAISES on a timeout, and an error inside a -c
#     command is printed and then ignored — nvim carried on to +qa and exited 0.
#     install() in turn RETURNS false for a language that did not build rather
#     than raising, so its result is checked too. Either way the exit status is
#     now 1, and the caller can say so.
#   * max_jobs: nvim-treesitter's default is 100 compilers at once. Under a 1 GiB
#     memory limit that was an OOM-killed cc1 part-way through, reported as a
#     clean run. At most four, fewer on a smaller machine.
#   * 30 minutes: the whole set builds in a few minutes with clang; the ceiling
#     is for a slow machine, not the expected case.
TS_BOOTSTRAP_LUA='local jobs = math.min(4, vim.uv.available_parallelism()) local ok, done = pcall(function() return require("nvim-treesitter").install(require("parsers"), { max_jobs = jobs }):wait(1800000) end) if not ok then io.stderr:write(tostring(done), "\n") end vim.cmd(ok and done and "qall!" or "cquit 1")'

bootstrap() {
	local nvim_bin
	nvim_bin="$(command -v nvim 2>/dev/null || true)"
	[ -n "$nvim_bin" ] || {
		warn "no nvim on PATH; skipping the headless bootstrap"
		note "run ':Lazy restore' and ':lua require(\"nvim-treesitter\").install(require(\"parsers\"))' yourself once nvim is on PATH."
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

	# Plugins at the pins in lazy-lock.json whenever there is one. This used to
	# run `:Lazy sync`, which is install + clean + UPDATE: every re-run upgraded
	# every plugin past the lock that install_config had just carried across.
	# `restore` checks out the locked commits instead; a plugin the lock does not
	# know yet is installed at startup by lazy.nvim itself. Upgrading stays a
	# deliberate `:Lazy sync` inside nvim.
	local lazy_cmd="install"
	[ -f "$CONFIG_DIR/lazy-lock.json" ] && lazy_cmd="restore"
	log "bootstrapping plugins (:Lazy $lazy_cmd)"
	# stdin closed: a headless nvim that hits a prompt with an attached terminal
	# blocks forever, which is how `curl | bash` installs hang.
	"${envv[@]}" "$nvim_bin" --headless "+Lazy! $lazy_cmd" "+Lazy! clean" +qa </dev/null >/dev/null 2>&1 ||
		note "':Lazy $lazy_cmd' did not finish cleanly; run it inside nvim."

	# The config's own startup install stays out of the way: it does not run in a
	# headless nvim (lua/essential/treesitter.lua), so this is the only install in
	# flight. It used to start first and hold every language, and this one then
	# waited on each for nvim-treesitter's 60 s per-language timeout and gave up.
	local tslog="$CACHE_DIR/parsers.log"
	mkdir -p -- "$CACHE_DIR"
	log "bootstrapping treesitter parsers (this can take a few minutes)"
	if "${envv[@]}" "$nvim_bin" --headless -c "lua $TS_BOOTSTRAP_LUA" </dev/null >"$tslog" 2>&1; then
		info "treesitter parsers: installed"
	else
		warn "the treesitter parser install failed; the end of $tslog:"
		tail -n 15 -- "$tslog" | sed 's/^/      /' >&2
		note "treesitter parsers are incomplete (log: $tslog). Fix what it reports, then re-run this script or run :TSInstall inside nvim."
	fi
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
