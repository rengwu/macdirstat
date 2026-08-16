#!/bin/bash
#
# Self-test for the project integrity check.
#
# Copies the repository skeleton into a temporary directory, breaks it one way
# at a time, and asserts the checker notices. Without this, "integrity check
# passed" only means the script ran.

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

# One pristine copy; each case re-copies from it.
pristine="$work/pristine"
mkdir -p "$pristine"
for item in MacDirStat.xcodeproj TestPlans App Scripts; do
	cp -R "$repo_root/$item" "$pristine/"
done
# The checker reads only package manifests. Copying SwiftPM's ignored `.build`
# trees made every mutation case duplicate gigabytes of irrelevant artifacts.
mkdir -p "$pristine/Packages/ScanCore" "$pristine/Packages/TreemapLayout"
cp "$repo_root/Packages/ScanCore/Package.swift" "$pristine/Packages/ScanCore/"
cp "$repo_root/Packages/TreemapLayout/Package.swift" "$pristine/Packages/TreemapLayout/"

expect() {
	local expected_status="$1" name="$2" breakage="$3"
	local sandbox="$work/$name"
	rm -rf "$sandbox"
	cp -R "$pristine" "$sandbox"

	( cd "$sandbox" && eval "$breakage" ) || {
		printf 'FAIL %s: could not stage the breakage\n' "$name"
		failures=$((failures + 1))
		return
	}

	local output status
	output="$(cd "$sandbox" && ./Scripts/check-project-integrity.py 2>&1)"
	status=$?

	if [ "$status" -eq "$expected_status" ]; then
		printf 'ok   %s (exit %d)\n' "$name" "$status"
	else
		printf 'FAIL %s: expected exit %d, got %d\n' "$name" "$expected_status" "$status"
		printf '%s\n' "$output" | sed 's/^/     /'
		failures=$((failures + 1))
	fi
}

pbxproj="MacDirStat.xcodeproj/project.pbxproj"

expect 0 unmodified_project 'true'

expect 1 missing_source_file \
	'rm App/MacDirStat/MainMenu.swift'

expect 1 unreferenced_source_file \
	'printf "import AppKit\n" > App/MacDirStat/Orphan.swift'

expect 1 raised_deployment_target \
	"sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 11.0/MACOSX_DEPLOYMENT_TARGET = 12.0/' $pbxproj"

expect 1 single_architecture \
	"sed -i '' 's/ARCHS = \"arm64 x86_64\"/ARCHS = arm64/' $pbxproj"

expect 1 mac_catalyst_enabled \
	"sed -i '' 's/SUPPORTS_MACCATALYST = NO/SUPPORTS_MACCATALYST = YES/' $pbxproj"

expect 1 release_builds_active_arch_only \
	"sed -i '' 's/ONLY_ACTIVE_ARCH = NO/ONLY_ACTIVE_ARCH = YES/' $pbxproj"

expect 1 dangling_object_reference \
	"sed -i '' 's/fileRef = AB000000000000000000F004/fileRef = AB000000000000000000FFFF/' $pbxproj"

# A source silently dropped from the compile phase leaves its PBXBuildFile
# defined but unreferenced — exactly the shape a bad merge produces.
expect 1 source_dropped_from_compile_phase \
	"python3 -c \"
path = '$pbxproj'
kept = [line for line in open(path)
        if not (line.strip().startswith('AB000000000000000000B004') and line.strip().endswith(','))]
open(path, 'w').writelines(kept)
\""

expect 1 storyboard_lifecycle \
	'/usr/libexec/PlistBuddy -c "Add :NSMainStoryboardFile string Main" App/MacDirStat/Info.plist'

expect 1 scheme_missing \
	'rm MacDirStat.xcodeproj/xcshareddata/xcschemes/MacDirStat-Performance.xcscheme'

expect 1 scheme_points_at_unknown_target \
	"sed -i '' 's/AB000000000000000000A001/AB0000000000000000009999/' MacDirStat.xcodeproj/xcshareddata/xcschemes/MacDirStat-CI.xcscheme"

expect 1 performance_scheme_in_debug \
	"sed -i '' 's/buildConfiguration = \"Release\"/buildConfiguration = \"Debug\"/' MacDirStat.xcodeproj/xcshareddata/xcschemes/MacDirStat-Performance.xcscheme"

expect 1 ci_plan_lost_a_target \
	'python3 -c "
import json
path = \"TestPlans/CI.xctestplan\"
plan = json.load(open(path))
plan[\"testTargets\"] = [t for t in plan[\"testTargets\"] if t[\"target\"][\"name\"] != \"TreemapLayoutTests\"]
json.dump(plan, open(path, \"w\"))
"'

expect 1 ci_plan_gained_the_performance_target \
	'python3 -c "
import json
path = \"TestPlans/CI.xctestplan\"
plan = json.load(open(path))
plan[\"testTargets\"].append({\"target\": {\"containerPath\": \"container:MacDirStat.xcodeproj\", \"identifier\": \"AB000000000000000000A004\", \"name\": \"MacDirStatPerformanceTests\"}})
json.dump(plan, open(path, \"w\"))
"'

expect 1 performance_plan_with_sanitizer \
	'python3 -c "
import json
path = \"TestPlans/Performance.xctestplan\"
plan = json.load(open(path))
plan[\"defaultOptions\"][\"threadSanitizerEnabled\"] = True
json.dump(plan, open(path, \"w\"))
"'

expect 1 thread_sanitizer_plan_without_the_sanitizer \
	'python3 -c "
import json
path = \"TestPlans/CI-ThreadSanitizer.xctestplan\"
plan = json.load(open(path))
plan[\"defaultOptions\"][\"threadSanitizerEnabled\"] = False
json.dump(plan, open(path, \"w\"))
"'

expect 1 package_test_target_removed \
	"sed -i '' 's/.testTarget(name: \"ScanCoreFileSystemTests\"/.testTarget(name: \"RenamedTests\"/' Packages/ScanCore/Package.swift"

if [ "$failures" -gt 0 ]; then
	printf '\n%d self-test(s) failed.\n' "$failures"
	exit 1
fi

printf '\nAll project integrity self-tests passed.\n'
exit 0
