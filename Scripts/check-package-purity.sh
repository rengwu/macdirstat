#!/bin/bash
#
# Framework-freedom check for the two local packages (spec §4.2, §10).
#
# `ScanCore` and `TreemapLayout` must import Foundation and no UI framework, so
# they unit-test headlessly and so the read-only guarantee stays structural —
# a package that cannot see AppKit cannot open a window, and one that cannot see
# CoreGraphics has to own its geometry types rather than borrow drawing ones.
#
# The import list comes from the compiler (`swiftc -emit-imported-modules`),
# not from grepping for the word "import", so a conditional or aliased import
# cannot slip past. Package.swift is checked separately for external
# dependencies and linked frameworks, which never reach the source files.
#
# Usage: Scripts/check-package-purity.sh [package-path ...]
#        (default: Packages/ScanCore Packages/TreemapLayout)

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
	packages=("Packages/ScanCore" "Packages/TreemapLayout")
fi

# Every UI, drawing and windowing framework the packages must stay clear of.
banned_modules="AppKit|SwiftUI|UIKit|Cocoa|Carbon|QuartzCore|CoreGraphics|CoreAnimation|CoreImage|WebKit|ImageIO|Metal|MetalKit|SceneKit|SpriteKit"

# The deployment floor these packages are compiled against (spec §4.2).
target_triple="$(uname -m)-apple-macos11.0"

failures=0

for package in "${packages[@]}"; do
	if [ ! -f "$package/Package.swift" ]; then
		printf 'error: %s has no Package.swift\n' "$package"
		failures=$((failures + 1))
		continue
	fi

	printf '== %s\n' "$package"

	sources=()
	while IFS= read -r file; do
		sources+=("$file")
	done < <(find "$package/Sources" "$package/Tests" -name '*.swift' -not -path '*/.build/*' 2>/dev/null | sort)

	if [ ${#sources[@]} -eq 0 ]; then
		printf 'error: %s has no Swift sources\n' "$package"
		failures=$((failures + 1))
		continue
	fi

	imports="$(swiftc -target "$target_triple" -module-name ImportAudit \
		-emit-imported-modules "${sources[@]}" 2>/dev/null | sort -u)"
	if [ -z "$imports" ]; then
		printf 'error: %s: could not read the compiler import list\n' "$package"
		failures=$((failures + 1))
		continue
	fi

	printf '   imports: %s\n' "$(printf '%s' "$imports" | tr '\n' ' ')"

	if ! printf '%s\n' "$imports" | grep -qx 'Foundation'; then
		printf 'error: %s does not import Foundation\n' "$package"
		failures=$((failures + 1))
	fi

	while IFS= read -r module; do
		[ -n "$module" ] || continue
		printf 'error: %s imports %s — the local packages are Foundation-only (spec §4.2)\n' \
			"$package" "$module"
		grep -rn "$module" "$package/Sources" "$package/Tests" 2>/dev/null |
			grep -E "import[[:space:]]+$module\b" | sed 's/^/       /'
		failures=$((failures + 1))
	done < <(printf '%s\n' "$imports" | grep -Ex "$banned_modules")

	# Package.swift may not pull in a framework the sources never name.
	if grep -qE 'linkedFramework|\.package\(' "$package/Package.swift"; then
		printf 'error: %s/Package.swift declares an external dependency or a linked framework\n' "$package"
		grep -nE 'linkedFramework|\.package\(' "$package/Package.swift" | sed 's/^/       /'
		failures=$((failures + 1))
	fi

	# The floor is part of the contract, not a default.
	if ! grep -q '\.macOS(\.v11)' "$package/Package.swift"; then
		printf 'error: %s/Package.swift does not pin the macOS 11.0 deployment floor (spec §4.2)\n' "$package"
		failures=$((failures + 1))
	fi
done

if [ "$failures" -gt 0 ]; then
	printf '\nPackage purity check failed: %d problem(s).\n' "$failures"
	exit 1
fi

printf '\nPackage purity check passed: Foundation-only, no UI framework, floor pinned at 11.0.\n'
exit 0
