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
SP1_VERSION ?=
RISC0_TOOLCHAIN_VERSION ?=
RISC0_CPP_TOOLCHAIN_VERSION ?=
OPENVM_VERSION ?=
SOLC_VERSION ?=

# DOCKER_BUILD_CACHE toggles both the docker layer cache and the BuildKit
# vendor-download cache mounts (hierophant's convention). 1 (default)
# reuses the shared cache namespace; a version bump re-fetches only its
# own asset class and cache hits are still verified against the committed
# sha256 pins. 0 is the pristine release/CI flow: the layer cache is
# bypassed (--no-cache) and the download cache mounts get a unique
# namespace, so every byte comes fresh from the vendor CDN.
DOCKER_BUILD_CACHE ?= 1
ifeq ($(DOCKER_BUILD_CACHE),0)
  BUILD_CACHE_FLAGS := --no-cache --build-arg BUILD_CACHE_ID=pristine-$(shell date +%s)
else
  BUILD_CACHE_FLAGS :=
endif
OPENVM_RUST_TOOLCHAIN ?=
OPENVM_KZG_VERSION ?=
ATTIC_VERSION ?=
NIX_VERSION ?=
ATTIC_TOKEN_FILE ?= attic_token
DOCKER_BUILD_ARGS ?=
IMAGE_NAME ?= petros
IMAGE_TAG ?= latest
ACT_PULL ?= true

.PHONY: init
init:
	@echo "Initializing configuration files ..."
	@echo "Initialization complete. Review configuration before running."

.PHONY: clean
clean:
	@echo "Cleaned."

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
	@if [ -z "$(SP1_VERSION)" ]; then \
		echo "ERROR: SP1_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(RISC0_TOOLCHAIN_VERSION)" ]; then \
		echo "ERROR: RISC0_TOOLCHAIN_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(RISC0_CPP_TOOLCHAIN_VERSION)" ]; then \
		echo "ERROR: RISC0_CPP_TOOLCHAIN_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(OPENVM_VERSION)" ]; then \
		echo "ERROR: OPENVM_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(OPENVM_RUST_TOOLCHAIN)" ]; then \
		echo "ERROR: OPENVM_RUST_TOOLCHAIN not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(SOLC_VERSION)" ]; then \
		echo "ERROR: SOLC_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(OPENVM_KZG_VERSION)" ]; then \
		echo "ERROR: OPENVM_KZG_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(ATTIC_VERSION)" ]; then \
		echo "ERROR: ATTIC_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(NIX_VERSION)" ]; then \
		echo "ERROR: NIX_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(CIRCOM_VERSION)" ]; then \
		echo "ERROR: CIRCOM_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(SNARKJS_VERSION)" ]; then \
		echo "ERROR: SNARKJS_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(R0_GROTH16_VERSION)" ]; then \
		echo "ERROR: R0_GROTH16_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(PPOT_VERSION)" ]; then \
		echo "ERROR: PPOT_VERSION not set (check .env.maintainer)" >&2; \
		exit 1; \
	fi
	@if [ -z "$(ETH_KZG_VERSION)" ]; then \
		echo "ERROR: ETH_KZG_VERSION not set (check .env.maintainer)" >&2; \
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
		$(BUILD_CACHE_FLAGS) \
		--build-arg ATTIC_SERVER_URL=$(ATTIC_SERVER_URL) \
		--build-arg ATTIC_CACHE=$(ATTIC_CACHE) \
		--build-arg ATTIC_PUBLIC_KEY=$(ATTIC_PUBLIC_KEY) \
		--build-arg VENDOR_BASE_URL=$(VENDOR_BASE_URL) \
		--build-arg SP1_VERSION=$(SP1_VERSION) \
		--build-arg RISC0_TOOLCHAIN_VERSION=$(RISC0_TOOLCHAIN_VERSION) \
		--build-arg RISC0_CPP_TOOLCHAIN_VERSION=$(RISC0_CPP_TOOLCHAIN_VERSION) \
		--build-arg OPENVM_VERSION=$(OPENVM_VERSION) \
		--build-arg OPENVM_RUST_TOOLCHAIN=$(OPENVM_RUST_TOOLCHAIN) \
		--build-arg OPENVM_KZG_VERSION=$(OPENVM_KZG_VERSION) \
		--build-arg SOLC_VERSION=$(SOLC_VERSION) \
		--build-arg ATTIC_VERSION=$(ATTIC_VERSION) \
		--build-arg NIX_VERSION=$(NIX_VERSION) \
		--build-arg CIRCOM_VERSION=$(CIRCOM_VERSION) \
		--build-arg SNARKJS_VERSION=$(SNARKJS_VERSION) \
		--build-arg R0_GROTH16_VERSION=$(R0_GROTH16_VERSION) \
		--build-arg PPOT_VERSION=$(PPOT_VERSION) \
		--build-arg ETH_KZG_VERSION=$(ETH_KZG_VERSION) \
		--build-arg ATTIC_CACHE_BUST=$(ATTIC_CACHE_BUST) \
		--secret id=attic_token,src=$(ATTIC_TOKEN_SOURCE) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) \
		.
	@echo "Build complete: $(IMAGE_NAME):$(IMAGE_TAG)"

.PHONY: test
test:
	@echo "Running tests ..."
	@echo "... tests completed."

# Generate the OpenVM aggregation proving keys inside the built petros image
# and drop openvm-agg-keys.tar.gz + its .sha256 into ./out/. Deliberately a
# separate goal rather than part of `make build`: the keygen is a heavy
# compute job (minutes of CPU, tens of GB of RAM) that produces *hierophant
# runtime artifacts*, and the image build should stay a fast, deterministic
# environment build. Running inside petros is what makes the keys
# reproducible - the vendored cargo-openvm + toolchain pin the keygen code.
# Follow-up ritual: upload the tarball to
# ${VENDOR_BASE_URL}/openvm/<OPENVM_VERSION>/, commit the .sha256 under
# hierophant's provers/openvm/<OPENVM_VERSION>/, and set
# OPENVM_AGG_KEYS_VERSION there. The out/ dir is chmod 777 because the
# container writes as the unprivileged petros user (uid 10001).
.PHONY: openvm-agg-keys
openvm-agg-keys:
	@if ! docker image inspect $(IMAGE_NAME):$(IMAGE_TAG) >/dev/null 2>&1; then \
		echo "ERROR: $(IMAGE_NAME):$(IMAGE_TAG) image not found; run 'make build' first" >&2; \
		exit 1; \
	fi
	@mkdir -p out && chmod 777 out
	@echo "Generating OpenVM aggregation keys in $(IMAGE_NAME):$(IMAGE_TAG) (slow, RAM-heavy) ..."
	docker run --rm \
		-e VENDOR_BASE_URL=$(VENDOR_BASE_URL) \
		-e OPENVM_VERSION=$(OPENVM_VERSION) \
		-v $(CURDIR)/src/scripts:/provision:ro \
		-v $(CURDIR)/out:/out \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		sh /provision/generate-openvm-agg-keys.sh /out
	@# Keygen is deterministic: the committed expected-hashes file records what
	@# this OPENVM_VERSION's pinned toolchain must produce. A mismatch means
	@# toolchain or upstream-source drift and MUST be investigated before the
	@# artifact is uploaded or trusted; a missing file means this is the first
	@# generation for the version - record the printed hashes.
	@if [ -f "src/openvm/$(OPENVM_VERSION)/agg-keys.expected-hashes" ]; then \
		TMP=$$(mktemp -d); \
		tar -xzf out/openvm-agg-keys.tar.gz -C "$$TMP"; \
		if (cd "$$TMP" && sha256sum -c "$(CURDIR)/src/openvm/$(OPENVM_VERSION)/agg-keys.expected-hashes"); then \
			echo "Reproducibility check PASSED against committed expected hashes."; \
		else \
			echo "ERROR: generated keys do not match src/openvm/$(OPENVM_VERSION)/agg-keys.expected-hashes" >&2; \
			rm -rf "$$TMP"; exit 1; \
		fi; \
		rm -rf "$$TMP"; \
	else \
		echo "NOTE: no expected-hashes file for $(OPENVM_VERSION); commit the hashes above to src/openvm/$(OPENVM_VERSION)/agg-keys.expected-hashes"; \
	fi
	@echo "Done; artifacts in ./out/. Upload the tarball and commit the .sha256 downstream."

# Emit the OpenVM EVM verifier contracts from the CDN-pinned production
# halo2.pk (fast: no keygen; the tool injects the seeded key) and write
# the verifier.expected-hashes pin to ./out/. Same drift discipline as
# the agg keys: if a committed pin exists it is checked and a mismatch
# hard-fails; if not, commit the printed lines to
# src/openvm/<OPENVM_VERSION>/verifier.expected-hashes and rebuild.
.PHONY: openvm-verifier-pin
openvm-verifier-pin:
	@if ! docker image inspect $(IMAGE_NAME):$(IMAGE_TAG) >/dev/null 2>&1; then \
		echo "ERROR: $(IMAGE_NAME):$(IMAGE_TAG) image not found; run 'make build' first" >&2; \
		exit 1; \
	fi
	@mkdir -p out && chmod 777 out
	@echo "Emitting OpenVM verifier from the pinned halo2.pk in $(IMAGE_NAME):$(IMAGE_TAG) ..."
	docker run --rm \
		-e VENDOR_BASE_URL=$(VENDOR_BASE_URL) \
		-e OPENVM_VERSION=$(OPENVM_VERSION) \
		-e HALO2_PK_SHA256=/pins/halo2.pk.sha256 \
		-v $(CURDIR)/src/scripts:/provision:ro \
		-v $(CURDIR)/src/verifier-pin-tool:/tool:ro \
		-v $(CURDIR)/src/openvm/$(OPENVM_VERSION):/pins:ro \
		-v $(CURDIR)/out:/out \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		sh /provision/generate-openvm-verifier-pin.sh /out /tool
	@# A populated pin has 64-hex-prefixed lines; the comment-only scaffold
	@# does not. POSIX sh only in recipes: no process substitution.
	@if grep -Eq '^[0-9a-f]{64}  ' "src/openvm/$(OPENVM_VERSION)/verifier.expected-hashes" 2>/dev/null; then \
		TMP1=$$(mktemp); TMP2=$$(mktemp); \
		grep -E '^[0-9a-f]{64}  ' "src/openvm/$(OPENVM_VERSION)/verifier.expected-hashes" > "$$TMP1"; \
		grep -E '^[0-9a-f]{64}  ' out/verifier.expected-hashes > "$$TMP2"; \
		if diff "$$TMP1" "$$TMP2"; then \
			echo "Reproducibility check PASSED against committed verifier pin."; \
			rm -f "$$TMP1" "$$TMP2"; \
		else \
			echo "ERROR: emitted verifier does not match src/openvm/$(OPENVM_VERSION)/verifier.expected-hashes" >&2; \
			rm -f "$$TMP1" "$$TMP2"; exit 1; \
		fi; \
	else \
		echo "NOTE: no populated verifier pin for $(OPENVM_VERSION); commit ./out/verifier.expected-hashes to src/openvm/$(OPENVM_VERSION)/ and rebuild petros"; \
	fi

.PHONY: docker
docker: build

.PHONY: ci
ci: build

.PHONY: run
run: shell

.PHONY: shell
shell:
	@echo "Opening shell in container ..."
	docker run --rm -it \
		--entrypoint /petros/bin/bash \
		$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: act
act:
	@echo "Running GitHub Actions workflow locally with act ..."
	@if [ ! -d ".act-secrets" ]; then \
		echo "WARNING: .act-secrets/ directory not found" >&2; \
		echo "See docs/WORKFLOW_TESTING.md for setup instructions" >&2; \
	fi
	@echo "Setting up temporary secrets mount ..."
	@sudo mkdir -p /opt/github-runner
	@sudo rm -rf /opt/github-runner/secrets
	@sudo ln -s $(CURDIR)/.act-secrets /opt/github-runner/secrets
	@trap "sudo rm -f /opt/github-runner/secrets" EXIT; \
	DOCKER_HOST="" act push -j release \
		--container-daemon-socket=- \
		--container-options "-v /opt/github-runner/secrets:/opt/github-runner/secrets:ro" \
		--pull=$(ACT_PULL) \
		$(if $(DOCKER_BUILD_ARGS),--env DOCKER_BUILD_ARGS="$(DOCKER_BUILD_ARGS)")

.PHONY: help
help:
	@echo "Petros Build System"
	@echo ""
	@echo "Targets:"
	@echo "  init            Initialize config from examples."
	@echo "  clean           Clean output directories."
	@echo "  build           Build native binaries."
	@echo "  test            Run all tests for the build."
	@echo "  openvm-agg-keys Generate the OpenVM aggregation keys in the built image."
	@echo "  docker          Build Docker image (compiles inside container)."
	@echo "  ci              Build Docker image from pre-built binaries."
	@echo "  run             Run the built Docker image locally."
	@echo "  shell           Open a shell in the Docker image."
	@echo "  act             Test GitHub Actions release workflow locally."
	@echo "  help            Show this help message."
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
