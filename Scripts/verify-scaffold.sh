#!/bin/bash
#
# The local gate, in one command (spec §9.1).
#
# Runs the four documented commands plus the guards, and reports honestly what
# it could not run. Exit codes:
#
#   0  everything ran and passed
#   1  something failed
#   2  everything that ran passed, but a step was skipped — usually because
#      only the Command Line Tools are installed, so there is no xcodebuild and
#      no XCTest. A skipped step is NOT a green gate.
#
# Usage: Scripts/verify-scaffold.sh

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

results=()
failed=0
skipped=0

run_step() {
	local name="$1"
	shift
	printf '\n\033[1m== %s\033[0m\n' "$name"
	if "$@"; then
		results+=("PASS    $name")
	else
		results+=("FAIL    $name")
		failed=$((failed + 1))
	fi
}

skip_step() {
	local name="$1" reason="$2"
	printf '\n\033[1m== %s\033[0m\n' "$name"
	printf 'skipped: %s\n' "$reason"
	results+=("SKIPPED $name — $reason")
	skipped=$((skipped + 1))
}

have_xcode() {
	xcodebuild -version >/dev/null 2>&1
}

have_xctest() {
	# swift test needs the XCTest bundled with Xcode; the Command Line Tools
	# ship the dylib but not the framework SwiftPM links against.
	xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1
}

parse_test_sources() {
	local sources=()
	while IFS= read -r file; do
		sources+=("$file")
	done < <(find App Packages -name '*Tests*.swift' -not -path '*/.build/*' | sort)
	printf 'parsing %d test source(s)...\n' "${#sources[@]}"
	swiftc -target "$(uname -m)-apple-macos11.0" -module-name ParseCheck -parse "${sources[@]}"
}

run_other_test_plans() {
	# The documented gate names one plan, CI. The other three are just as
	# hand-authored, and a plan Xcode cannot read fails at the *scheme*, not in
	# any check that reads the file as JSON — `Performance` shipped from ticket
	# 02 with a `loggingType` Xcode rejects and no local step noticed. So run
	# each of them once too.
	local status=0 pair
	set -- \
		"MacDirStat-CI:CI-ThreadSanitizer" \
		"MacDirStat-CompatibilitySmoke:CompatibilitySmoke"
	for pair in "$@"; do
		printf '\n-- scheme %s, plan %s\n' "${pair%%:*}" "${pair##*:}"
		xcodebuild test -project MacDirStat.xcodeproj -scheme "${pair%%:*}" \
			-testPlan "${pair##*:}" -destination 'platform=macOS' || status=1
	done

	# The performance plan carries two configurations (ticket 10). The default
	# one runs Smoke and the cheap stress shapes in a few seconds, which is what
	# this gate wants: proof the plan is readable and the suite compiles and
	# passes. `Release, all rungs` is the opt-in pre-release-candidate gate — it
	# climbs to two million entries and writes its record into `.plan/`, so
	# running it here would dirty the working tree on every local check. Name
	# the light configuration explicitly, because xcodebuild runs *all* of a
	# plan's configurations when told none.
	printf '\n-- scheme MacDirStat-Performance, plan Performance (light configuration)\n'
	xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-Performance \
		-testPlan Performance -only-test-configuration 'Release, no sanitizer' \
		-destination 'platform=macOS' || status=1

	return $status
}

typecheck_app_sources() {
	local status=0 arch
	for arch in arm64 x86_64; do
		if have_xcode; then
			printf 'compiling App/MacDirStat and local-package imports for %s at the 11.0 floor...\n' "$arch"
			xcodebuild build -quiet -project MacDirStat.xcodeproj -scheme MacDirStat \
				-configuration Debug -destination 'generic/platform=macOS' \
				ARCHS="$arch" ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=11.0 \
				CODE_SIGNING_ALLOWED=NO || status=1
		else
			# A bare swiftc invocation cannot resolve Xcode's local-package
			# products. Parsing still catches syntax errors; the Xcode steps are
			# reported skipped below, so this never overstates a green gate.
			printf 'parsing App/MacDirStat for %s (Xcode package resolution unavailable)...\n' "$arch"
			swiftc -target "$arch-apple-macos11.0" -parse App/MacDirStat/*.swift || status=1
		fi
	done
	return $status
}

# ---------------------------------------------------------------- guards ----

run_step "Guard self-tests: post-Big-Sur APIs" Scripts/tests/test-check-post-bigsur-apis.sh
run_step "Guard self-tests: package purity" Scripts/tests/test-check-package-purity.sh
run_step "Guard self-tests: project integrity" Scripts/tests/test-check-project-integrity.sh

run_step "Post-Big-Sur API source review (spec §4.4)" Scripts/check-post-bigsur-apis.sh
run_step "Package framework-freedom (spec §4.2)" Scripts/check-package-purity.sh
run_step "Project/scheme/test-plan integrity" Scripts/check-project-integrity.py

# ------------------------------------------------- the documented commands ----

if have_xctest; then
	run_step "swift test --package-path Packages/ScanCore" \
		swift test --package-path Packages/ScanCore
	run_step "swift test --package-path Packages/TreemapLayout" \
		swift test --package-path Packages/TreemapLayout
else
	run_step "swift build --package-path Packages/ScanCore" \
		swift build --package-path Packages/ScanCore
	run_step "swift build --package-path Packages/TreemapLayout" \
		swift build --package-path Packages/TreemapLayout
	# Without XCTest nothing can compile the test sources, so at least prove
	# they parse — a typo there would otherwise wait for a machine with Xcode.
	run_step "Test sources parse" parse_test_sources
	skip_step "swift test (both packages)" \
		"XCTest is unavailable — install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'"
fi

run_step "App sources compile, both architectures, floor 11.0" typecheck_app_sources

if have_xcode; then
	run_step "xcodebuild test -scheme MacDirStat-CI -testPlan CI" \
		xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI \
		-testPlan CI -destination 'platform=macOS'
	run_step "xcodebuild build -scheme MacDirStat -configuration Release (universal)" \
		xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat \
		-configuration Release -destination 'generic/platform=macOS' \
		ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=11.0
	run_step "The other three test plans run" run_other_test_plans
else
	skip_step "xcodebuild test -scheme MacDirStat-CI -testPlan CI" \
		"no xcodebuild — this machine has the Command Line Tools only"
	skip_step "xcodebuild build -scheme MacDirStat -configuration Release (universal)" \
		"no xcodebuild — this machine has the Command Line Tools only"
	skip_step "The other three test plans run" \
		"no xcodebuild — this machine has the Command Line Tools only"
fi

# --------------------------------------------------------------- summary ----

printf '\n\033[1m== Summary\033[0m\n'
for result in "${results[@]}"; do
	printf '%s\n' "$result"
done

if [ "$failed" -gt 0 ]; then
	printf '\n%d step(s) failed.\n' "$failed"
	exit 1
fi

if [ "$skipped" -gt 0 ]; then
	printf '\nEverything that ran passed, but %d step(s) were skipped — the gate is not green.\n' \
		"$skipped"
	exit 2
fi

printf '\nAll steps passed.\n'
exit 0
