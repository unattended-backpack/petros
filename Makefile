# Makefile for building Petros.
#
# Configuration is loaded from `.env.maintainer` and can be overridden by
# environment variables.
#
# Usage:
#   make build                    # Build using `.env.maintainer`.
#   ATTIC_CACHE=other make build  # Override specific variables.

# Load configuration from `.env.maintainer` if it exists.
-include .env.maintainer

# Allow environment variable overrides with defaults.
ATTIC_SERVER_URL ?=
ATTIC_CACHE ?=
ATTIC_PUBLIC_KEY ?=
VENDOR_BASE_URL ?=
ATTIC_TOKEN_FILE ?= attic_token
DOCKER_BUILD_ARGS ?=
IMAGE_NAME ?= petros
IMAGE_TAG ?= latest
ACT_PULL ?= true

.PHONY: build
build:
	@echo "Building Petros Docker image ..."
	@if [ -z "$(ATTIC_SERVER_URL)" ]; then \
		echo "ERROR: ATTIC_SERVER_URL not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(ATTIC_CACHE)" ]; then \
		echo "ERROR: ATTIC_CACHE not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(ATTIC_PUBLIC_KEY)" ]; then \
		echo "ERROR: ATTIC_PUBLIC_KEY not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(VENDOR_BASE_URL)" ]; then \
		echo "ERROR: VENDOR_BASE_URL not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ ! -f "$(ATTIC_TOKEN_FILE)" ]; then \
		echo "ERROR: Token file '$(ATTIC_TOKEN_FILE)' not found" >&2; \
		exit 1; \
	fi
	@# Use .attic_admin_token if it exists, otherwise use attic_token
	$(eval ATTIC_TOKEN_SOURCE := $(shell [ -f .attic_admin_token ] && echo .attic_admin_token || echo $(ATTIC_TOKEN_FILE)))
	@echo "Using attic token: $(ATTIC_TOKEN_SOURCE)"
	$(eval ATTIC_CACHE_BUST := $(shell sha256sum $(ATTIC_TOKEN_SOURCE) | cut -d' ' -f1))
	docker build \
		$(DOCKER_BUILD_ARGS) \
		--build-arg ATTIC_SERVER_URL=$(ATTIC_SERVER_URL) \
		--build-arg ATTIC_CACHE=$(ATTIC_CACHE) \
		--build-arg ATTIC_PUBLIC_KEY=$(ATTIC_PUBLIC_KEY) \
		--build-arg VENDOR_BASE_URL=$(VENDOR_BASE_URL) \
		--build-arg ATTIC_CACHE_BUST=$(ATTIC_CACHE_BUST) \
		--secret id=attic_token,src=$(ATTIC_TOKEN_SOURCE) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) \
		.
	@echo "Build complete: $(IMAGE_NAME):$(IMAGE_TAG)"

.PHONY: act
act:
	@echo "Running GitHub Actions workflow locally with act ..."
	@if [ ! -d ".act-secrets" ]; then \
		echo "WARNING: .act-secrets/ directory not found" >&2; \
		echo "See TESTING.md for setup instructions" >&2; \
	fi
	act push -j release \
		--pull=$(ACT_PULL) \
		--container-options "-v $(CURDIR)/.act-secrets:/opt/github-runner/secrets:ro --group-add 960" \
		$(if $(DOCKER_BUILD_ARGS),--env DOCKER_BUILD_ARGS="$(DOCKER_BUILD_ARGS)")

.PHONY: help
help:
	@echo "Petros Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build    Build the Petros Docker image."
	@echo "  act      Test GitHub Actions release workflow locally."
	@echo "  help     Show this help message."
	@echo ""
	@echo "Configuration:"
	@echo "  Variables are loaded from .env.maintainer"
	@echo "  Override with environment variables:"
	@echo "    ATTIC_SERVER_URL   - URL of your attic server"
	@echo "    ATTIC_CACHE        - Name of the attic cache"
	@echo "    ATTIC_PUBLIC_KEY   - Public key for signature verification"
	@echo "    ATTIC_TOKEN_FILE   - Path to token file (default: attic_token)"
	@echo "    DOCKER_BUILD_ARGS  - Additional Docker build flags"
	@echo "    IMAGE_NAME         - Docker image name (default: petros)"
	@echo "    IMAGE_TAG          - Docker image tag (default: latest)"
	@echo ""
	@echo "Example:"
	@echo "  make build"
	@echo "  ATTIC_CACHE=production make build"
	@echo "  DOCKER_BUILD_ARGS='--network host' make build"

.DEFAULT_GOAL := build
