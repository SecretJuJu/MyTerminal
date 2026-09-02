APP_NAME = MyTerminal
BUNDLE = $(APP_NAME).app
BIN = .build/debug/$(APP_NAME)
# swift-testing ships in Xcode's toolchain, not the Command Line Tools, so
# `swift test` fails when xcode-select still points at the CLT. Override with
# `make test XCODE=/path/to/Xcode.app/Contents/Developer` if yours lives elsewhere.
XCODE = /Applications/Xcode.app/Contents/Developer
.PHONY: build run test bundle icon clean

build:
	swift build

run: build
	./$(BIN)

# Separate scratch path on purpose: Xcode and the Command Line Tools ship
# different Swift versions, and sharing .build makes each toolchain reject the
# other's modules ("module compiled with Swift x cannot be imported by y").
test:
	DEVELOPER_DIR=$(XCODE) swift test --scratch-path .build/test


bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp -R .build/debug/GhosttyKit_GhosttyTerminal.bundle $(BUNDLE)/Contents/Resources/
	cp Support/AppIcon.icns $(BUNDLE)/Contents/Resources/
	@echo "built $(BUNDLE) — open $(BUNDLE)"

# Support/AppIcon.svg를 다시 구워 Support/AppIcon.icns를 만든다. 아이콘을
# 고쳤을 때만 부르면 된다 — 결과물은 커밋돼 있고 bundle은 그걸 복사한다.
# rsvg나 ImageMagick이 필요 없는 이유는 NSImage가 SVG를 직접 읽기 때문이다.
icon:
	DEVELOPER_DIR=$(XCODE) swift Support/make-icon.swift
	iconutil -c icns -o Support/AppIcon.icns .build/AppIcon.iconset

clean:
	swift package clean
	rm -rf .build/test
