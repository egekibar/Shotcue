APP_NAME     := Shotcue
BUNDLE_ID    := com.shotcue.app
SIGN_IDENTITY ?= Shotcue Dev
INSTALL_DIR  := $(HOME)/Applications

# CLT-only SwiftPM intermittently fails to resolve the Swift Testing macro plugin on the first build
# ("plugin for module 'TestingMacros' not found", measured on this machine 2026-09-22). Loading it explicitly
# makes `make test` deterministic. The path is skipped automatically when it does not exist (e.g. with Xcode).
TESTING_PLUGIN   := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGIN)),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN),)

.PHONY: build build-release test bundle bundle-release dmg notarize cask install run shot reset-tcc format lint clean cert

build: ; swift build
build-release: ; swift build -c release
# Usage: make test            (everything)   |   make test FILTER='ModelsTests|TitleMakerTests'   (regex on suite/test names)
test: ; @swift test $(SWIFT_TEST_FLAGS) $(if $(FILTER),--filter '$(FILTER)',)
bundle: build ; ./scripts/bundle.sh "$(APP_NAME)" "$(BUNDLE_ID)" "$(SIGN_IDENTITY)"
# Distribution: arm64 release bundle in dist/release/, then dist/<App>-<version>.dmg + .sha256 packed from it.
# Neither target installs or launches anything. Sign with another identity: make dmg SIGN_IDENTITY='…'
bundle-release: build-release ; ./scripts/bundle.sh "$(APP_NAME)" "$(BUNDLE_ID)" "$(SIGN_IDENTITY)" release
dmg: bundle-release ; ./scripts/make-dmg.sh "$(APP_NAME)"
# Needs a Developer ID identity and a notarytool keychain profile (docs/distribution.md):
#   make notarize SIGN_IDENTITY='Developer ID Application: …'      (NOTARY_PROFILE defaults to shotcue-notary)
notarize: dmg ; ./scripts/notarize.sh "$(APP_NAME)"
# After the GitHub release is published: point the egekibar/tap cask at it (version + the release's SHA-256) and push.
cask: ; ./scripts/bump-cask.sh "$(APP_NAME)"
install: bundle ; ./scripts/install.sh "$(APP_NAME)" "$(INSTALL_DIR)"
run: install ; open "$(INSTALL_DIR)/$(APP_NAME).app"
shot: ; ./scripts/shot.sh "$(APP_NAME)"
cert: ; ./scripts/make-cert.sh "$(SIGN_IDENTITY)"
reset-tcc: ; tccutil reset ScreenCapture $(BUNDLE_ID); tccutil reset Microphone $(BUNDLE_ID)
format: ; xcrun swift-format format --in-place --recursive Sources Tests
lint: ; xcrun swift-format lint --strict --recursive Sources Tests
clean: ; rm -rf .build dist
