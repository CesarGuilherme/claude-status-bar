APP := macos/build/ClaudeStatusBar.app

.PHONY: app install test dump

app:
	macos/scripts/build-app.sh

install: app
	-pkill -x ClaudeStatusBar
	rm -rf /Applications/ClaudeStatusBar.app
	ditto $(APP) /Applications/ClaudeStatusBar.app
	open /Applications/ClaudeStatusBar.app

test:
	cd macos && swift test

dump:
	cd macos && swift run ClaudeStatusBar --dump
