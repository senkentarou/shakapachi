CODESIGN_IDENTITY ?= Developer ID Application: Masahiro Senda (U2H8U2TN85)

APP_NAME      := ShakaPachi
BUNDLE_DIR    := dist/$(APP_NAME).app
CONTENTS_DIR  := $(BUNDLE_DIR)/Contents
MACOS_DIR     := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources

.PHONY: build run release test clean icon notarize format lint

# Debug build: compile, assemble .app bundle, and sign.
build:
	swift build 2>&1
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp .build/debug/$(APP_NAME) "$(MACOS_DIR)/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	@cp Resources/AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"
	@cp -R Resources/en.lproj "$(RESOURCES_DIR)/"
	@cp -R Resources/ja.lproj "$(RESOURCES_DIR)/"
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE_DIR)"

# Regenerate the app icon (.icns) from tools/make-icon.swift.
icon:
	swift tools/make-icon.swift Resources

# Build then launch the app.
# SHAKAPACHI_DEADMAN_SEC: the DEBUG deadman auto-disables the event tap after N
# seconds as a dev safety net. The app is stable now and the auto-disable was
# interrupting normal use, so `make run` sets it to 0 (disabled). Temporarily
# disabling window switching from the menu bar remains the safety net, and
# Release builds never include the deadman (#if DEBUG only). Override with
# `make run DEADMAN_SEC=60`.
DEADMAN_SEC ?= 0
run: build
	open "$(BUNDLE_DIR)" --env SHAKAPACHI_DEADMAN_SEC=$(DEADMAN_SEC)

# Release build: compile with optimisations, assemble, and sign.
release:
	swift build -c release 2>&1
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp .build/release/$(APP_NAME) "$(MACOS_DIR)/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	@cp Resources/AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"
	@cp -R Resources/en.lproj "$(RESOURCES_DIR)/"
	@cp -R Resources/ja.lproj "$(RESOURCES_DIR)/"
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE_DIR)"

# Notarize a release build. Requires a stored notarytool credential profile
# (create once with: xcrun notarytool store-credentials shakapachi-notary
#   --apple-id <id> --team-id U2H8U2TN85 --password <app-specific-password>).
# Overridable: make notarize NOTARY_PROFILE=<name>
NOTARY_PROFILE ?= shakapachi-notary
notarize: release
	ditto -c -k --keepParent "$(BUNDLE_DIR)" dist/ShakaPachi.zip
	xcrun notarytool submit dist/ShakaPachi.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(BUNDLE_DIR)"

# Run unit tests.
test:
	swift test 2>&1

# swift-format is bundled with the Swift toolchain (Swift 5.8+ / Xcode 14.3+)
# and is invoked as the `swift format` subcommand — no separate install needed.
# (If your toolchain predates the bundled subcommand, `brew install swift-format`
#  and replace `swift format` with `swift-format` below.)
# Configuration lives in .swift-format at the repo root.

# Reformat all sources in place.
format:
	swift format --configuration .swift-format --in-place --recursive Sources Tests

# Lint without modifying files; fails on any violation (CI-friendly).
lint:
	swift format lint --configuration .swift-format --strict --recursive Sources Tests

# Remove build artefacts.
clean:
	rm -rf .build dist
