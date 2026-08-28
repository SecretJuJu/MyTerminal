APP_NAME = MyTerminal
BUNDLE = $(APP_NAME).app
BIN = .build/debug/$(APP_NAME)
# swift-testing ships in Xcode's toolchain, not the Command Line Tools, so
# `swift test` fails when xcode-select still points at the CLT. Override with
# `make test XCODE=/path/to/Xcode.app/Contents/Developer` if yours lives elsewhere.
XCODE = /Applications/Xcode.app/Contents/Developer
.PHONY: build run test bundle clean

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
	@echo "built $(BUNDLE) — open $(BUNDLE)"

clean:
	swift package clean
	rm -rf .build/test
