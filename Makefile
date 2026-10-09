# Death Race for Code
#
#   make test        run the package tests (portable targets on Linux; everything on macOS)
#   make esctest     run xterm's conformance suite against the engine (needs python3)
#   make fuzz        fuzz the engine with libFuzzer for FUZZ_SECONDS (swift.org toolchain)
#   make bench       measure engine throughput (release build)
#   make vtdiff      VTCore next to SwiftTerm: throughput, and every corpus screen in both
#   make lint        swift-format lint
#   make run         build, bundle, sign and open the app (macOS)
#   make smoke       bundle, run the app's headless --smoke-test, save build/smoke-frame.png (macOS)
#   make test-render corpus screens drawn by the GPU against PNG goldens (macOS with a real GPU)
#   make bundle      build "Death Race for Code.app" into build/ (macOS)
#   make install-swift-linux   install the swift.org toolchain on Ubuntu

PKG := Packages/DeathRaceKit
APP := build/Death Race for Code.app

.PHONY: test test-render esctest fuzz bench vtdiff lint check-imports check-expect-messages check-any-optional format run smoke bundle clean install-swift-linux

FUZZ := Tools/VTFuzz
DIFF := Tools/VTDiff
FUZZ_SECONDS ?= 60

test:
	swift test --package-path $(PKG)

# A missing golden is written to Packages/DeathRaceKit/Tests/Fixtures/render and its test fails:
# look at the PNG, commit it, and run again.
test-render:
	DEATHRACE_RENDER_GOLDENS=1 swift test --package-path $(PKG) --filter RenderGoldenTests

esctest:
	scripts/esctest.sh

# Xcode's toolchain has no libFuzzer runtime; use the swift.org one (Linux, or macOS with it
# installed). New inputs collect in $(FUZZ)/.build/corpus; a crash leaves crash-* there too.
fuzz:
	swift build --package-path $(FUZZ) -c release -Xswiftc -sanitize=fuzzer,address
	python3 $(FUZZ)/make-seeds.py $(FUZZ)/.build/corpus
	mkdir -p $(FUZZ)/.build/artifacts
	$(FUZZ)/.build/release/VTFuzz -max_total_time=$(FUZZ_SECONDS) -timeout=10 -rss_limit_mb=4096 \
		-print_final_stats=1 -artifact_prefix=$(FUZZ)/.build/artifacts/ $(FUZZ)/.build/corpus

bench:
	swift run --package-path $(PKG) -c release vthost bench

# SwiftTerm is a referee, fetched at a pinned commit into a package of its own.
vtdiff:
	swift build --package-path $(DIFF) -c release
	$(DIFF)/.build/release/vtdiff bench --seconds 2
	$(DIFF)/.build/release/vtdiff corpus --verbose $(PKG)/Tests/Fixtures/corpus

SWIFT_SOURCES := $(PKG)/Sources $(PKG)/Tests $(PKG)/Tools $(PKG)/Package.swift $(FUZZ)/Sources $(FUZZ)/Package.swift \
	$(DIFF)/Sources $(DIFF)/Package.swift

lint: check-imports check-expect-messages check-any-optional
	swift format lint --recursive --strict $(SWIFT_SOURCES)

# A type the macOS-only sources name but cannot reach. `swiftc -parse` is syntax only, so
# this is otherwise found by a macOS runner rather than here (see docs/ARCHITECTURE.md,
# known risks).
check-imports:
	python3 scripts/check-imports.py

# An expectation message that is a `String` rather than a string literal. Same reason as
# above: only a macOS runner compiles DeathRaceAppTests, so this would otherwise cost a round.
check-expect-messages:
	python3 scripts/check-expect-messages.py

check-any-optional:
	python3 scripts/check-any-optional.py

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

bundle:
	scripts/bundle.sh

run: bundle
	open "$(APP)"

smoke:
	CONFIG=debug scripts/bundle.sh
	"$(APP)/Contents/MacOS/DeathRace" --smoke-test --write-frame build/smoke-frame.png

clean:
	rm -rf build $(PKG)/.build $(FUZZ)/.build $(DIFF)/.build

install-swift-linux:
	scripts/install-swift-linux.sh
