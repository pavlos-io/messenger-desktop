APP_NAME := Messenger
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SOURCES := $(wildcard Sources/*.swift)

.PHONY: all run clean install

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Info.plist AppIcon.icns
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	swiftc $(SOURCES) \
		-o "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" \
		-framework Cocoa \
		-framework WebKit \
		-target arm64-apple-macosx13.0 \
		-swift-version 5
	@cp Info.plist "$(APP_BUNDLE)/Contents/"
	@cp AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	@echo "Built $(APP_BUNDLE)"

run: $(APP_BUNDLE)
	@open "$(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

install: $(APP_BUNDLE)
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"
