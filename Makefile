# nvim-config — development targets.
#
# Nothing here is needed to USE this repository; the installer depends on bash,
# curl, git and coreutils and nothing else. These targets are for working ON it,
# and they are exactly what the $CI_SHELL pipeline component drives, so CI and a
# laptop can never disagree about what a gate is.
#
# shellcheck and shfmt come from containers by default, so there is nothing to
# install. A local binary is used instead when one is on PATH — which is how the
# fleet shell-ci image runs them. Override with `make lint USE_DOCKER=1`.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# --- what to lint ----------------------------------------------------------
# Every shell file in the checkout has to be on this list; tests/policy/
# lint-coverage.sh is the tripwire that fails the build when one is not.
SH_FILES := install.sh tests/policy/lint-coverage.sh

# --- how to reach the tools ------------------------------------------------
# Pinned, not `:stable`/`:latest`: a floating linter tag means CI and a laptop
# can disagree about whether the tree is clean. These match what the fleet
# shell-ci image bakes in.
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.11.0
SHFMT_IMAGE      ?= mvdan/shfmt:v3.12.0
DOCKER           ?= docker
USE_DOCKER       ?=

DOCKER_RUN = $(DOCKER) run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR):/mnt" -w /mnt

ifeq ($(USE_DOCKER),1)
  SHELLCHECK ?= $(DOCKER_RUN) $(SHELLCHECK_IMAGE)
  SHFMT      ?= $(DOCKER_RUN) $(SHFMT_IMAGE)
else
  SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo '$(DOCKER_RUN) $(SHELLCHECK_IMAGE)')
  SHFMT      ?= $(shell command -v shfmt 2>/dev/null || echo '$(DOCKER_RUN) $(SHFMT_IMAGE)')
endif

# Tab indentation — this repository's existing style, and `-i 0` is what keeps
# it. (linux-devops-tools uses `-i 2 -ci -bn`; do not copy that here without
# reformatting the whole tree in the same commit.)
SHFMT_FLAGS ?= -i 0
SHELLCHECK_FLAGS ?= -x -P . -S style

# --- a gate that is not in the checkout is a FAILURE, never a skip ----------
gate = @test -f '$(1)' || { \
         printf 'MISSING GATE: %s is not in this checkout.\n' '$(1)' >&2; \
         printf 'A gate that is not here has not passed. Restore it, or delete the target that runs it.\n' >&2; \
         exit 1; \
       }

.PHONY: help syntax lint fmt fmt-check lint-coverage check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{ printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }'

syntax: ## Parse every script with `bash -n` (fast, no tools needed)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@printf 'bash -n: %s files OK\n' '$(words $(SH_FILES))'

lint: ## shellcheck every script (container by default)
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SH_FILES)

fmt: ## Reformat every script in place with shfmt
	$(SHFMT) -w $(SHFMT_FLAGS) $(SH_FILES)

fmt-check: ## Fail if any script is not shfmt-clean
	$(SHFMT) -d $(SHFMT_FLAGS) $(SH_FILES)

# MIN_FILES is the tripwire's floor: lint-coverage.sh defaults it to 40, which is
# linux-devops-tools' size, and a repo this small would fail on that alone. Set to
# the exact count, so a wildcard or a rename that drops a file still trips it.
lint-coverage: ## Fail if a shell file in the checkout is on nobody's lint list
	$(call gate,tests/policy/lint-coverage.sh)
	@MIN_FILES=2 bash tests/policy/lint-coverage.sh $(SH_FILES)

check: lint-coverage syntax lint fmt-check ## Everything CI runs
