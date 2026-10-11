# crate-agent — common operations
# Run `make` (no arguments) for a summary of available targets.

.DEFAULT_GOAL := help
SHELL := /bin/bash

# make's child shells don't source ~/.zshrc, so cargo (installed under
# ~/.cargo/bin by rustup) may not be on PATH. Resolve it explicitly:
# use the PATH lookup if it works, otherwise fall back to the
# canonical rustup install location. The `?=` lets a caller override
# via `make CARGO=/path/to/cargo ...`.
CARGO ?= $(shell command -v cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)
RUSTUP ?= $(shell command -v rustup 2>/dev/null || echo $(HOME)/.cargo/bin/rustup)

DERIVED_DATA_PATH := $(CURDIR)/build-output/DerivedData
APP_PATH := $(DERIVED_DATA_PATH)/Build/Products/Debug/CrateAgent.app

.PHONY: help install-deps doctor build build-rust xcodeproj \
        test test-rust test-swift run clean format lint

help: ## Print this help summary
	@echo "crate-agent — make targets"
	@echo ""
	@echo "  Setup"
	@echo "    make install-deps   Install Rust toolchain + xcodegen + swiftformat"
	@echo "    make doctor         Verify required tools are installed and on PATH"
	@echo ""
	@echo "  Build"
	@echo "    make build          Full build: Rust core + Xcode project + app"
	@echo "    make build-rust     Build only the Rust core (universal static lib + Swift bindings)"
	@echo "    make xcodeproj      Regenerate CrateAgent.xcodeproj from project.yml"
	@echo ""
	@echo "  Test"
	@echo "    make test           Run all tests (Rust + Swift)"
	@echo "    make test-rust      Run only Rust core tests"
	@echo "    make test-swift     Run only Swift app tests"
	@echo ""
	@echo "  Format / lint"
	@echo "    make format         cargo fmt + swiftformat"
	@echo "    make lint           cargo clippy (warnings = errors)"
	@echo ""
	@echo "  Misc"
	@echo "    make run            Open the built CrateAgent.app (must build first)"
	@echo "    make clean          Remove all build artifacts"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

install-deps:
	@echo "==> Checking Rust toolchain..."
	@if command -v cargo >/dev/null 2>&1; then \
	    echo "    cargo is installed ($$(cargo --version))"; \
	else \
	    echo "    Installing rustup + cargo..."; \
	    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path; \
	    echo "    Add \$$HOME/.cargo/bin to your PATH (e.g., in ~/.zshrc):"; \
	    echo "        export PATH=\"\$$HOME/.cargo/bin:\$$PATH\""; \
	fi
	@echo "==> Checking xcodegen..."
	@if command -v xcodegen >/dev/null 2>&1; then \
	    echo "    xcodegen is installed ($$(xcodegen --version 2>&1 | head -1))"; \
	else \
	    echo "    Installing xcodegen via Homebrew..."; \
	    brew install xcodegen; \
	fi
	@echo "==> Checking swiftformat..."
	@if command -v swiftformat >/dev/null 2>&1; then \
	    echo "    swiftformat is installed ($$(swiftformat --version))"; \
	else \
	    echo "    Installing swiftformat via Homebrew..."; \
	    brew install swiftformat; \
	fi
	@echo "==> Dependency setup complete."
	@echo "    Note: Xcode itself must be installed via the App Store."
	@echo "    After installing Xcode, run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

doctor:
	@printf "%-15s " "cargo:"; \
	    (command -v cargo >/dev/null && cargo --version) || echo "MISSING — run 'make install-deps'"
	@printf "%-15s " "rustup:"; \
	    (command -v rustup >/dev/null && rustup --version | head -1) || echo "MISSING — run 'make install-deps'"
	@printf "%-15s " "xcodegen:"; \
	    (command -v xcodegen >/dev/null && xcodegen --version 2>&1 | head -1) || echo "MISSING — run 'brew install xcodegen'"
	@printf "%-15s " "xcodebuild:"; \
	    (command -v xcodebuild >/dev/null && xcodebuild -version 2>&1 | head -1) || echo "MISSING — install Xcode via App Store"
	@printf "%-15s " "swiftformat:"; \
	    (command -v swiftformat >/dev/null && swiftformat --version) || echo "MISSING — run 'brew install swiftformat'"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build: build-rust xcodeproj
	@echo "==> Building CrateAgent.app (Debug)..."
	xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Debug -derivedDataPath "$(DERIVED_DATA_PATH)" build

build-rust:
	@echo "==> Building Rust core (universal arm64 + x86_64 static lib + Swift bindings)..."
	./scripts/build-rust.sh

xcodeproj:
	@echo "==> Regenerating CrateAgent.xcodeproj from project.yml..."
	xcodegen generate

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

test: test-rust test-swift

test-rust:
	@echo "==> Running Rust tests..."
	$(CARGO) test --manifest-path rust-core/Cargo.toml --workspace

test-swift: xcodeproj
	@echo "==> Running Swift tests..."
	xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test -derivedDataPath "$(DERIVED_DATA_PATH)" test

# ---------------------------------------------------------------------------
# Format & lint
# ---------------------------------------------------------------------------

format:
	@echo "==> cargo fmt..."
	$(CARGO) fmt --manifest-path rust-core/Cargo.toml --all
	@if command -v swiftformat >/dev/null 2>&1; then \
	    echo "==> swiftformat..."; \
	    swiftformat CrateAgent CrateAgentTests; \
	else \
	    echo "(swiftformat not installed; skipping Swift formatting)"; \
	fi

lint:
	@echo "==> cargo clippy (warnings = errors)..."
	$(CARGO) clippy --manifest-path rust-core/Cargo.toml --workspace -- -D warnings

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

run:
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "No built app found at $(APP_PATH)"; \
	    echo "Run 'make build' first."; \
	    exit 1; \
	fi
	@echo "Opening $(APP_PATH)"
	open "$(APP_PATH)"

clean:
	@echo "==> Removing build artifacts..."
	rm -rf rust-core/target
	rm -rf build-output
	rm -rf CrateAgent/Generated
	rm -rf CrateAgent.xcodeproj
	@echo "    Done."
	@echo "    Builds made directly in Xcode are not removed."
