PREFIX ?= /Applications
APP = dist/TkTracker.app
BIN = .build/release/TkTracker
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

.PHONY: build test release app install run clean icon zip

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
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

zip: app
	ditto -c -k --sequesterRsrc --keepParent $(APP) dist/TkTracker-$(VERSION).zip
	@echo "built dist/TkTracker-$(VERSION).zip"

install: app
	rm -rf "$(PREFIX)/TkTracker.app"
	ditto $(APP) "$(PREFIX)/TkTracker.app"
	@echo "installed to $(PREFIX)/TkTracker.app — launch it from Spotlight or Finder"

run: app
	open $(APP)

clean:
	rm -rf .build dist
