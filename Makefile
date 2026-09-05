# MacDirStat — development tasks.
#
# Everything builds into .build/xcode rather than Xcode's shared DerivedData,
# so the path is predictable, the tree stays clean (.build/ is gitignored) and
# a `make clean` cannot take anything else with it.

PROJECT      := MacDirStat.xcodeproj
SCHEME       := MacDirStat
CI_SCHEME    := MacDirStat-CI
TEST_PLAN    := CI
DESTINATION  := platform=macOS
DERIVED      := .build/xcode
CONFIG       := Debug
BUNDLE_ID    := com.macdirstat.MacDirStat

APP          := $(DERIVED)/Build/Products/$(CONFIG)/$(SCHEME).app
BINARY       := $(APP)/Contents/MacOS/$(SCHEME)
# Matches the dev build only, so a copy installed in /Applications is left be.
RUNNING      := $(CONFIG)/$(SCHEME).app/Contents/MacOS

XCODEBUILD   := xcodebuild -project $(PROJECT) -destination '$(DESTINATION)'

.DEFAULT_GOAL := help
.PHONY: help build run rerun console stop release test test-packages test-app reset clean

help: ## List the targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build the debug app
	@$(XCODEBUILD) build -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

run: build ## Build and launch the dev instance
	@touch "$(APP)"
	@# Refresh Launch Services after an in-place build so it reloads the app icon.
	@/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$(APP)"
	@open $(APP)

rerun: stop run ## Quit a running dev instance, rebuild, and launch it again

console: stop build ## Launch in the terminal, with the app's console output attached
	@echo "==> $(BINARY)  (ctrl-C to quit)"
	@$(BINARY)

stop: ## Quit a running dev instance
	@pkill -f '$(RUNNING)' 2>/dev/null && echo "==> stopped" || echo "==> not running"

release: ## Build the release app
	@$(XCODEBUILD) build -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED)

test: ## Run everything: both packages, then the app target
	@$(MAKE) --no-print-directory test-packages
	@$(MAKE) --no-print-directory test-app

test-app: ## Run the app target's tests only
	@$(XCODEBUILD) test -scheme $(CI_SCHEME) -testPlan $(TEST_PLAN) -derivedDataPath $(DERIVED)

test-packages: ## Run the two Foundation-only packages headlessly (~3s)
	@swift test --package-path Packages/ScanCore
	@swift test --package-path Packages/TreemapLayout

reset: ## Forget the persisted window state — dividers, sort, Fast mode, recents
	@defaults delete $(BUNDLE_ID) 2>/dev/null && echo "==> cleared $(BUNDLE_ID)" \
		|| echo "==> nothing stored for $(BUNDLE_ID)"

clean: ## Remove the build directory
	@rm -rf $(DERIVED)
	@echo "==> removed $(DERIVED)"
