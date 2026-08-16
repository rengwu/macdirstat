#!/bin/bash
#
# Post-Big-Sur API source-review guard (spec §4.4).
#
# The macOS 11.0 floor puts four SwiftUI APIs out of reach: `Table` (12.0+),
# `Canvas` (12.0+), `NavigationSplitView` (13.0+) and `searchable`. Compiler
# availability checking is necessary but NOT sufficient here — a `Canvas` in a
# `some View` body is diagnosed only as a *warning* about conformance
# availability, so it can reach a Big Sur machine unguarded. This guard is the
# backstop: it fails on any use of the watch-list that a human has not marked as
# reviewed.
#
# `NSSearchField` (10.0+) is the permitted search control; the guard reports its
# use count so the affirmation is visible in the log rather than assumed.
#
# A use that a human has genuinely reviewed and guarded is exempted by putting
# the marker below on the line itself or the line above it:
#
#     // compat-reviewed: <reason, e.g. "guarded by if #available(macOS 12, *)">
#
# Usage: Scripts/check-post-bigsur-apis.sh [path ...]   (default: App Packages)

set -o pipefail

REVIEW_MARKER="compat-reviewed"

roots=("$@")
if [ ${#roots[@]} -eq 0 ]; then
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	cd "$repo_root" || exit 2
	roots=("App" "Packages")
fi

# label|regex — the regexes match uses, not the bare word, so prose in a doc
# comment about `Canvas` cannot trip the guard. Comment lines are stripped
# before matching in any case.
watch_list=(
	"SwiftUI.Table (macOS 12.0+)|(SwiftUI\.Table|[^[:alnum:]_]Table[[:space:]]*[({])"
	"SwiftUI.Canvas (macOS 12.0+)|[^[:alnum:]_]Canvas[[:space:]]*[({]"
	"SwiftUI.NavigationSplitView (macOS 13.0+)|NavigationSplitView"
	"SwiftUI .searchable (above the floor — use NSSearchField)|\.searchable[[:space:]]*\("
)

swift_sources() {
	local root
	for root in "${roots[@]}"; do
		[ -e "$root" ] || continue
		find "$root" -name '*.swift' -not -path '*/.build/*' -print
	done
}

# Emits `lineno:text` for code lines only — whole-line `//`, `///`, `*` and
# `/*` comments are dropped so the guard reads code, not documentation. A
# leading space is prepended to each text so the watch-list's "not preceded by
# an identifier character" patterns can match at the start of a line.
code_lines() {
	grep -n '' "$1" | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' | sed 's/^\([0-9]*\):/\1: /'
}

violations=0
searchfield_uses=0

while IFS= read -r file; do
	[ -n "$file" ] || continue
	stripped="$(code_lines "$file")"
	[ -n "$stripped" ] || continue

	for entry in "${watch_list[@]}"; do
		label="${entry%%|*}"
		pattern="${entry#*|}"

		while IFS= read -r hit; do
			[ -n "$hit" ] || continue
			lineno="${hit%%:*}"
			text="${hit#*: }"

			previous_line=$((lineno > 1 ? lineno - 1 : 1))
			previous="$(sed -n "${previous_line}p" "$file")"
			if printf '%s\n%s\n' "$text" "$previous" | grep -q "$REVIEW_MARKER"; then
				printf 'note: %s:%s uses %s, marked %s\n' "$file" "$lineno" "$label" "$REVIEW_MARKER"
				continue
			fi

			printf 'error: %s:%s uses %s — above the macOS 11.0 floor (spec §4.4)\n' \
				"$file" "$lineno" "$label"
			printf '       %s\n' "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
			violations=$((violations + 1))
		done < <(printf '%s\n' "$stripped" | grep -E "$pattern")
	done

	count=$(printf '%s\n' "$stripped" | grep -cE 'NSSearchField')
	searchfield_uses=$((searchfield_uses + count))
done < <(swift_sources)

printf 'NSSearchField is the permitted search control (spec §4.4): %d use(s) found.\n' \
	"$searchfield_uses"

if [ "$violations" -gt 0 ]; then
	printf 'Compatibility guard failed: %d unreviewed post-Big-Sur API use(s).\n' "$violations"
	exit 1
fi

printf 'Compatibility guard passed: no unreviewed post-Big-Sur API use.\n'
exit 0
