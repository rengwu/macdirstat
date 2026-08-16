#!/bin/bash
#
# Self-test for the package purity check (spec §4.2).
#
# Stages throwaway packages in a temporary directory and asserts the check
# catches a UI-framework import, a missing Foundation import, an external
# dependency and a missing deployment floor — and passes a clean package.

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/Scripts/check-package-purity.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

stage_package() {
	local name="$1" platforms="$2" dependencies="$3" source="$4"
	local dir="$work/$name"
	mkdir -p "$dir/Sources/Module" "$dir/Tests/ModuleTests"
	cat >"$dir/Package.swift" <<EOF
// swift-tools-version:5.7
import PackageDescription
let package = Package(
    name: "Module",
    platforms: [$platforms],
    dependencies: [$dependencies],
    targets: [.target(name: "Module"), .testTarget(name: "ModuleTests", dependencies: ["Module"])]
)
EOF
	printf '%s\n' "$source" >"$dir/Sources/Module/Module.swift"
	printf 'import XCTest\n@testable import Module\nfinal class T: XCTestCase {}\n' \
		>"$dir/Tests/ModuleTests/ModuleTests.swift"
	printf '%s' "$dir"
}

expect() {
	local expected_status="$1" name="$2" dir="$3"
	local output status
	output="$("$checker" "$dir" 2>&1)"
	status=$?

	if [ "$status" -eq "$expected_status" ]; then
		printf 'ok   %s (exit %d)\n' "$name" "$status"
	else
		printf 'FAIL %s: expected exit %d, got %d\n' "$name" "$expected_status" "$status"
		printf '%s\n' "$output" | sed 's/^/     /'
		failures=$((failures + 1))
	fi
}

expect 0 accepts_foundation_only \
	"$(stage_package clean '.macOS(.v11)' '' 'import Foundation
public enum Module { public static let floor = "11.0" }')"

expect 1 rejects_appkit \
	"$(stage_package appkit '.macOS(.v11)' '' 'import Foundation
import AppKit
public enum Module {}')"

expect 1 rejects_swiftui \
	"$(stage_package swiftui '.macOS(.v11)' '' 'import Foundation
import SwiftUI
public enum Module {}')"

expect 1 rejects_coregraphics \
	"$(stage_package coregraphics '.macOS(.v11)' '' 'import Foundation
import CoreGraphics
public enum Module {}')"

expect 1 rejects_missing_foundation \
	"$(stage_package nofoundation '.macOS(.v11)' '' 'public enum Module {}')"

expect 1 rejects_external_dependency \
	"$(stage_package dependency '.macOS(.v11)' '.package(url: "https://example.com/x.git", from: "1.0.0")' 'import Foundation
public enum Module {}')"

expect 1 rejects_missing_floor \
	"$(stage_package nofloor '.macOS(.v12)' '' 'import Foundation
public enum Module {}')"

if [ "$failures" -gt 0 ]; then
	printf '\n%d self-test(s) failed.\n' "$failures"
	exit 1
fi

printf '\nAll purity self-tests passed.\n'
exit 0
