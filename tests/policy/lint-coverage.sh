#!/usr/bin/env bash
#
# tests/policy/lint-coverage.sh — the lint list still covers the tree.
#
# The Makefile builds SH_FILES out of $(wildcard …). A wildcard that matches
# nothing expands to nothing and says nothing about it, so:
#
#   * rename modules/ and `make lint` shellchecks 28 fewer files, exits 0
#   * add tools/release.sh and nothing lints it, ever, and nothing says so
#
# Both are the same failure as a policy rule that greps a tree of untracked files
# and reports "clean": the gate did not find a violation because the gate did not
# look. This closes it from the other end — every shell file git knows about must
# be on the list the linters are given.
#
# Usage:
#     bash tests/policy/lint-coverage.sh <file>…    # the list, from $(SH_FILES)
#     bash tests/policy/lint-coverage.sh --self-test
#     make lint-coverage
#
# The file list comes from `git ls-files --cached --others --exclude-standard`,
# so it sees a brand new file the moment it is written, not once it is committed.

set -euo pipefail

PROG=${0##*/}
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)

# A tree this size cannot legitimately drop below this many shell files. The
# floor is what turns "the wildcards matched nothing" from a pass into a failure;
# the per-file comparison below cannot do it alone, because if git also stops
# answering, both sides go empty and agree.
MIN_FILES=${MIN_FILES:-40}

FAIL=0
bad() {
	printf '%s  %s\n' 'LINT-COVERAGE' "$*" >&2
	FAIL=$((FAIL + 1))
}

# shell_files ROOT — every file in the checkout that a shell linter should see:
# anything named *.sh or *.bash, plus anything whose first line is a sh/bash
# shebang (that is how bin/devenv and config/bin/* are written).
shell_files() {
	local root=$1 f first
	{
		# `git rev-parse`, NOT `[ -d .git ]`: in a `git worktree` checkout .git is a
		# FILE, the -d test is false, and this drops into the find fallback — a
		# different enumerator over a different set of files, in the branch nobody
		# runs. Ask git whether this is a work tree instead.
		if command -v git >/dev/null 2>&1 &&
			git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			git -C "$root" ls-files --cached --others --exclude-standard
		else
			(cd "$root" && find . -type f -printf '%P\n')
		fi
	} | {
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			case $f in
			.git/* | */.git/*) continue ;;
			*.sh | *.bash)
				printf '%s\n' "$f"
				continue
				;;
			esac
			[ -f "$root/$f" ] || continue
			if [ -L "$root/$f" ]; then continue; fi
			first=$(head -n 1 -- "$root/$f" 2>/dev/null || true)
			case $first in
			'#!'*) ;;
			*) continue ;;
			esac
			if printf '%s' "$first" | grep -qE '(bash|dash|/sh|env[[:space:]]+sh)([[:space:]]|$)'; then
				printf '%s\n' "$f"
			fi
		done
	} | LC_ALL=C sort -u
}

check() {
	local root=$1
	shift
	local -a listed=("$@")
	local f n

	n=${#listed[@]}
	if [ "$n" -lt "$MIN_FILES" ]; then
		bad "only $n file(s) on the lint list, expected at least $MIN_FILES."
		printf '  A wildcard in SH_FILES stopped matching. A shorter list is not a\n' >&2
		printf '  cleaner repository — it is a linter that was handed less work.\n' >&2
	fi

	# Every listed file must exist. A wildcard that matched nothing leaves nothing
	# behind, but a hand-written entry (install.sh) rots silently.
	for f in ${listed[0]+"${listed[@]}"}; do
		[ -e "$root/$f" ] || bad "the lint list names a file that is not here: $f"
	done

	local -a want=()
	mapfile -t want < <(shell_files "$root")
	if [ "${#want[@]}" -eq 0 ]; then
		bad 'found no shell file in the checkout at all — the file walk is broken'
		return 0
	fi

	local listed_sorted
	listed_sorted=$(printf '%s\n' ${listed[0]+"${listed[@]}"} | LC_ALL=C sort -u)
	local missing
	missing=$(printf '%s\n' "${want[@]}" | LC_ALL=C comm -23 - <(printf '%s\n' "$listed_sorted"))

	if [ -n "$missing" ]; then
		bad 'shell file(s) in the checkout that no linter is given:'
		printf '%s\n' "$missing" | sed 's/^/      /' >&2
		printf '  Add them to SH_FILES in the Makefile, or delete them.\n' >&2
	fi

	[ "$FAIL" -eq 0 ] &&
		printf '%s: %d shell file(s) in the checkout, all on the lint list\n' "$PROG" "${#want[@]}"
	return 0
}

# ---------------------------------------------------------------------------
# Self-test — plant a shell file that is not on the list, and a list that a
# collapsed wildcard would produce, and prove both are caught.
# ---------------------------------------------------------------------------

self_test() {
	local dir rc=0
	dir=$(mktemp -d "${TMPDIR:-/tmp}/lintcov-selftest.XXXXXXXX")
	# shellcheck disable=SC2064  # expand now: a fresh mktemp path
	trap "rm -rf -- '$dir'" EXIT
	mkdir -p "$dir/tools" "$dir/bin"

	local i
	for i in $(seq 1 45); do
		printf '#!/usr/bin/env bash\nset -euo pipefail\n' >"$dir/tools/t$i.sh"
	done
	# Extension-less, but a bash shebang: this is how bin/devenv is written, and
	# an extension-only walk would miss it.
	printf '#!/usr/bin/env bash\nset -euo pipefail\n' >"$dir/bin/devenv"
	printf 'not a script\n' >"$dir/bin/README"

	local -a all=()
	mapfile -t all < <(shell_files "$dir")

	printf '%s: self-test — the findings below are SYNTHETIC and expected\n' "$PROG" >&2

	case " ${all[*]} " in
	*' bin/devenv '*) printf '  ok    an extension-less bash script is picked up by its shebang\n' ;;
	*)
		printf '  FAIL  bin/devenv was not recognised as a shell script\n'
		rc=1
		;;
	esac
	case " ${all[*]} " in
	*' bin/README '*)
		printf '  FAIL  a plain text file was treated as a shell script\n'
		rc=1
		;;
	*) printf '  ok    a plain text file is not treated as a shell script\n' ;;
	esac

	# 1. the complete list is accepted
	FAIL=0
	check "$dir" "${all[@]}" >/dev/null 2>&1
	if [ "$FAIL" -eq 0 ]; then
		printf '  ok    a complete lint list is accepted\n'
	else
		printf '  FAIL  %d finding(s) on a complete lint list\n' "$FAIL"
		rc=1
	fi

	# 2. one file left off the list — the "nobody lints this" case
	FAIL=0
	local -a short=()
	for i in "${all[@]}"; do
		[ "$i" = 'bin/devenv' ] || short+=("$i")
	done
	check "$dir" "${short[@]}" >/dev/null 2>&1
	if [ "$FAIL" -gt 0 ]; then
		printf '  ok    a shell file missing from the list is reported\n'
	else
		printf '  FAIL  a shell file missing from the list was accepted\n'
		rc=1
	fi

	# 3. the collapsed wildcard — a list far shorter than the tree
	FAIL=0
	check "$dir" 'bin/devenv' >/dev/null 2>&1
	if [ "$FAIL" -gt 0 ]; then
		printf '  ok    a collapsed wildcard list is reported\n'
	else
		printf '  FAIL  a one-entry lint list was accepted for a 46-file tree\n'
		rc=1
	fi

	# 4. a list naming a file that is not there
	FAIL=0
	check "$dir" "${all[@]}" 'tools/deleted.sh' >/dev/null 2>&1
	if [ "$FAIL" -gt 0 ]; then
		printf '  ok    a lint list naming a deleted file is reported\n'
	else
		printf '  FAIL  a lint list naming a deleted file was accepted\n'
		rc=1
	fi

	FAIL=0
	[ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
	return "$rc"
}

main() {
	case ${1:-} in
	--self-test)
		self_test
		return
		;;
	'')
		printf 'usage: %s <file>… | --self-test\n' "$PROG" >&2
		printf 'The list is SH_FILES from the Makefile; run it through: make lint-coverage.\n' >&2
		return 64
		;;
	esac

	check "$ROOT" "$@"
	if [ "$FAIL" -gt 0 ]; then
		printf '\n%s: %d finding(s)\n' "$PROG" "$FAIL" >&2
		return 1
	fi
	return 0
}

main "$@"
