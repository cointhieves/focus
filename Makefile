# Build and install Focus without Xcode or an Apple developer account.
# Needs only the Xcode Command Line Tools (`xcode-select --install`).
# Locally built apps carry no quarantine flag, so Gatekeeper does not prompt.

APP_DIR   ?= $(HOME)/Applications
BIN_DIR   ?= $(HOME)/.local/bin
BUILD     := .build/release
BUNDLE    := build/Focus.app

.PHONY: build test app install uninstall clean share

build:
	swift build -c release

# Command Line Tools ship the Swift Testing framework but not on the default
# search path (only full Xcode wires it up), so point swift test at it.
CLT_DEV := $(shell xcode-select -p)/Library/Developer
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
              -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	# Company settings (see README "Using Focus at another company"); make vars override.
	mkdir -p $(BUNDLE)/Contents/Resources
	# Resources/Org.local.plist (git-ignored) wins, so your own values never get committed.
	cp $(if $(wildcard Resources/Org.local.plist),Resources/Org.local.plist,Resources/Org.plist) $(BUNDLE)/Contents/Resources/Org.plist
	$(if $(JIRA_SITE),/usr/libexec/PlistBuddy -c "Set :JiraSite $(JIRA_SITE)" $(BUNDLE)/Contents/Resources/Org.plist)
	$(if $(SLACK_CLIENT_ID),/usr/libexec/PlistBuddy -c "Set :SlackClientID $(SLACK_CLIENT_ID)" $(BUNDLE)/Contents/Resources/Org.plist)
	@for k in JiraSite SlackClientID; do \
	  v=$$(/usr/libexec/PlistBuddy -c "Print :$$k" $(BUNDLE)/Contents/Resources/Org.plist 2>/dev/null); \
	  [ -n "$$v" ] || echo "WARNING: $$k is empty in Resources/Org.plist; see README 'Before you build'."; \
	done
	cp $(BUILD)/FocusApp $(BUNDLE)/Contents/MacOS/FocusApp
	# Ad-hoc signature (no developer identity) so the bundle is internally consistent.
	codesign --force --sign - $(BUNDLE)

# A zip to hand to someone at another company: committed source with the company values
# blanked, plus the README and Slack manifest alongside. Usage: make share OUT=~/Desktop/focus
OUT ?= build/share
share:
	mkdir -p $(OUT)
	git archive --format=tar --prefix=focus/ HEAD | tar -x -C $(OUT)
	/usr/libexec/PlistBuddy -c "Set :JiraSite ''" -c "Set :SlackClientID ''" $(OUT)/focus/Resources/Org.plist
	cd $(OUT) && rm -f focus-src.zip && zip -qr focus-src.zip focus && rm -r focus
	cp README.md slack-app-manifest.yaml $(OUT)/
	@echo "Share bundle in $(OUT): focus-src.zip (company values blank), README.md, slack-app-manifest.yaml"

install: app
	mkdir -p $(APP_DIR) $(BIN_DIR)
	rm -rf $(APP_DIR)/Focus.app
	cp -R $(BUNDLE) $(APP_DIR)/Focus.app
	cp $(BUILD)/focus $(BIN_DIR)/focus
	@echo "Installed $(APP_DIR)/Focus.app and $(BIN_DIR)/focus"
	@# Restart so the new build is the one running (it also turns on Open at login the first time).
	-@pkill -x FocusApp; sleep 1
	open $(APP_DIR)/Focus.app

uninstall:
	rm -rf $(APP_DIR)/Focus.app $(BIN_DIR)/focus

clean:
	rm -rf .build build
