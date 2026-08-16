#!/bin/bash
#
# Self-test for the post-Big-Sur API guard (spec §4.4).
#
# A guard nobody has watched fail is not a guard. This stages fixture sources in
# a temporary directory and asserts the guard flags each watch-list API, honours
# the review marker, ignores prose in comments, and passes clean code.

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/Scripts/check-post-bigsur-apis.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

expect() {
	local expected_status="$1" name="$2" source="$3"
	local dir="$work/$name"
	mkdir -p "$dir"
	printf '%s\n' "$source" >"$dir/Fixture.swift"

	local output status
	output="$("$guard" "$dir" 2>&1)"
	status=$?

	if [ "$status" -eq "$expected_status" ]; then
		printf 'ok   %s (exit %d)\n' "$name" "$status"
	else
		printf 'FAIL %s: expected exit %d, got %d\n' "$name" "$expected_status" "$status"
		printf '%s\n' "$output" | sed 's/^/     /'
		failures=$((failures + 1))
	fi
}

expect 1 flags_table 'import SwiftUI
struct V: View { var body: some View { Table(rows) { } } }'

expect 1 flags_qualified_table 'import SwiftUI
let t = SwiftUI.Table(rows)'

expect 1 flags_canvas 'import SwiftUI
struct V: View { var body: some View { Canvas { context, size in } } }'

expect 1 flags_navigation_split_view 'import SwiftUI
struct V: View { var body: some View { NavigationSplitView { A() } detail: { B() } } }'

expect 1 flags_searchable 'import SwiftUI
struct V: View { var body: some View { List().searchable(text: $query) } }'

expect 0 allows_reviewed_use 'import SwiftUI
struct V: View {
	var body: some View {
		// compat-reviewed: guarded below, Big Sur takes the fallback path
		if #available(macOS 12.0, *) { Canvas { context, size in } } else { Fallback() }
	}
}'

expect 0 ignores_prose_in_comments 'import AppKit
/// Table, Canvas, NavigationSplitView and searchable are all above the floor.
// Canvas(…) in prose must not trip the guard.
let field = NSSearchField()'

expect 0 allows_nssearchfield 'import AppKit
let field = NSSearchField()
let table = NSTableView()'

expect 0 allows_clean_appkit 'import AppKit
final class Controller: NSViewController {}'

if [ "$failures" -gt 0 ]; then
	printf '\n%d self-test(s) failed.\n' "$failures"
	exit 1
fi

printf '\nAll guard self-tests passed.\n'
exit 0
