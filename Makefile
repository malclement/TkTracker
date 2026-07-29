PREFIX ?= /Applications
APP = dist/TkTracker.app
BIN = .build/release/TkTracker
RESOURCE_BUNDLE = .build/release/TkTracker_TkTracker.bundle
ENTITLEMENTS = Support/TkTracker.entitlements
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

# Signing identity. Unset (the default) means ad-hoc: the app builds and runs
# locally but Gatekeeper will quarantine it on another Mac. Set it to a
# "Developer ID Application: …" identity to produce a distributable build:
#   make app SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= -

# Notarization credentials. Either store a keychain profile once —
#   xcrun notarytool store-credentials tktracker --apple-id … --team-id … --password …
# and use NOTARY_PROFILE=tktracker, or pass APPLE_ID / TEAM_ID / APP_PASSWORD.
NOTARY_PROFILE ?=
APPLE_ID ?=
TEAM_ID ?=
APP_PASSWORD ?=

.PHONY: build test release app install run clean icon zip notarize verify-signature verify-signature-strict verify-resources help

help:
	@echo "TkTracker $(VERSION)"
	@echo ""
	@echo "  make build              debug build"
	@echo "  make test               unit tests"
	@echo "  make app                dist/TkTracker.app (release, icon, signed)"
	@echo "  make zip                distributable zip"
	@echo "  make notarize           zip + submit to Apple + staple (needs credentials)"
	@echo "  make verify-signature   check signature, runtime flags and staple"
	@echo "  make install            copy to $(PREFIX)"
	@echo "  make run                build and launch"
	@echo "  make clean              remove build output"
	@echo ""
	@echo "  Signing identity: $(SIGN_IDENTITY)"

build:
	swift build

test:
	swift test

release:
	swift build -c release

icon: dist/AppIcon.icns

dist/AppIcon.icns: Scripts/MakeIcon.swift
	mkdir -p dist/AppIcon.iconset
	swift Scripts/MakeIcon.swift dist/AppIcon.iconset
	iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns

app: release dist/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/TkTracker
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp dist/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	# SwiftPM emits target resources as a separate bundle beside the binary.
	# Bundle.module resolves it through Bundle.main.resourceURL, so it has to be
	# copied in — without it pricing.json is missing and the app silently falls
	# back to the compiled-in rate table.
	cp -R $(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	# Sign inner bundles before the outer one: codesign seals what it finds, so
	# signing the .app first would leave the nested bundle unsigned inside a
	# sealed container and fail verification.
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" \
		"$(APP)/Contents/Resources/TkTracker_TkTracker.bundle"
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" $(APP)
	@$(MAKE) --no-print-directory verify-resources
	@echo "built $(APP) (identity: $(SIGN_IDENTITY))"
ifeq ($(SIGN_IDENTITY),-)
	@echo ""
	@echo "  NOTE: ad-hoc signed. Fine on this Mac; on any other one the user"
	@echo "  must clear the quarantine flag by hand. For distribution, build"
	@echo "  with SIGN_IDENTITY set and run 'make notarize'."
endif

zip: app
	ditto -c -k --sequesterRsrc --keepParent $(APP) dist/TkTracker-$(VERSION).zip
	@echo "built dist/TkTracker-$(VERSION).zip"

# Submit to Apple, wait for the ticket, staple it into the app, then re-zip so
# the distributed archive carries the staple. A stapled app passes Gatekeeper
# offline; without the staple the first launch needs network to check.
notarize: zip
ifeq ($(SIGN_IDENTITY),-)
	@echo "error: notarization needs a Developer ID identity." >&2
	@echo "       make notarize SIGN_IDENTITY=\"Developer ID Application: … (TEAMID)\"" >&2
	@exit 1
endif
	@if [ -n "$(NOTARY_PROFILE)" ]; then \
		xcrun notarytool submit dist/TkTracker-$(VERSION).zip \
			--keychain-profile "$(NOTARY_PROFILE)" --wait; \
	elif [ -n "$(APPLE_ID)" ] && [ -n "$(TEAM_ID)" ] && [ -n "$(APP_PASSWORD)" ]; then \
		xcrun notarytool submit dist/TkTracker-$(VERSION).zip \
			--apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)" --password "$(APP_PASSWORD)" --wait; \
	else \
		echo "error: set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD" >&2; \
		exit 1; \
	fi
	xcrun stapler staple $(APP)
	rm -f dist/TkTracker-$(VERSION).zip
	ditto -c -k --sequesterRsrc --keepParent $(APP) dist/TkTracker-$(VERSION).zip
	@echo "notarized and stapled dist/TkTracker-$(VERSION).zip"

# Asserts the packaged app can reach its resources, using the app's own binary
# so Bundle.main is the .app. The resolved path must be *inside* the bundle: a
# developer-machine fallback resolving to .build would otherwise let a broken
# copy ship and crash on every other Mac.
verify-resources:
	@echo "== bundled resources =="
	@set -e; \
	out="$$($(APP)/Contents/MacOS/TkTracker --selfcheck)" || { \
		echo "$$out" | sed 's/^/  /'; \
		echo "error: selfcheck failed — the app cannot reach its bundled resources" >&2; \
		exit 1; }; \
	echo "$$out" | sed 's/^/  /'; \
	echo "$$out" | grep -q "pricing.json $(CURDIR)/$(APP)/" || { \
		echo "error: pricing.json did not resolve inside the app bundle." >&2; \
		echo "       $(APP)/Contents/Resources must contain TkTracker_TkTracker.bundle." >&2; \
		exit 1; }; \
	echo "  resources resolve inside the bundle"

verify-signature:
	@echo "== signature =="
	codesign --verify --deep --strict --verbose=2 $(APP)
	@echo "== runtime flags & entitlements =="
	codesign --display --verbose=4 --entitlements - $(APP) 2>&1 | grep -E 'flags|Identifier|Authority|network' || true
	@echo "== gatekeeper =="
	spctl --assess --type execute --verbose=4 $(APP) || \
		echo "  (rejected — expected for an ad-hoc build; notarize for distribution)"
	@echo "== staple =="
	xcrun stapler validate $(APP) || echo "  (no ticket stapled)"

# CI gate after notarization. Unlike verify-signature above, nothing here is
# tolerated: the release notes assert the build is notarized and stapled, so an
# artifact that cannot prove it must fail the job rather than be published.
verify-signature-strict: verify-resources
	codesign --verify --deep --strict --verbose=2 $(APP)
	codesign --display --verbose=4 $(APP) 2>&1 | grep -q 'flags=.*runtime' \
		|| { echo "error: hardened runtime flag not set" >&2; exit 1; }
	spctl --assess --type execute --verbose=4 $(APP)
	xcrun stapler validate $(APP)
	@echo "signature, hardened runtime, Gatekeeper and staple all verified"

install: app
	rm -rf "$(PREFIX)/TkTracker.app"
	ditto $(APP) "$(PREFIX)/TkTracker.app"
	@echo "installed to $(PREFIX)/TkTracker.app — launch it from Spotlight or Finder"

run: app
	open $(APP)

clean:
	rm -rf .build dist
