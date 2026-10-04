# Death Race for Code
#
#   make test        run the package tests (portable targets on Linux; everything on macOS)
#   make esctest     run xterm's conformance suite against the engine (needs python3)
#   make bench       measure engine throughput (release build)
#   make lint        swift-format lint
#   make run         build, bundle, sign and open the app (macOS)
#   make smoke       bundle, then run the app's headless --smoke-test (macOS)
#   make bundle      build "Death Race for Code.app" into build/ (macOS)
#   make install-swift-linux   install the swift.org toolchain on Ubuntu

PKG := Packages/DeathRaceKit
APP := build/Death Race for Code.app

.PHONY: test esctest bench lint format run smoke bundle clean install-swift-linux

test:
	swift test --package-path $(PKG)

esctest:
	scripts/esctest.sh

bench:
	swift run --package-path $(PKG) -c release vthost bench

lint:
	swift format lint --recursive --strict $(PKG)/Sources $(PKG)/Tests $(PKG)/Tools $(PKG)/Package.swift

format:
	swift format --in-place --recursive $(PKG)/Sources $(PKG)/Tests $(PKG)/Tools $(PKG)/Package.swift

bundle:
	scripts/bundle.sh

run: bundle
	open "$(APP)"

smoke:
	CONFIG=debug scripts/bundle.sh
	"$(APP)/Contents/MacOS/DeathRace" --smoke-test

clean:
	rm -rf build $(PKG)/.build

install-swift-linux:
	scripts/install-swift-linux.sh
