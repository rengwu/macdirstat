#!/usr/bin/env python3
"""Structural check of MacDirStat.xcodeproj, its schemes and its test plans.

Xcode is the only thing that can prove the project *builds*. This checks the
things a broken hand-edit or a bad merge breaks first, and which xcodebuild
reports late and badly: dangling object references, file references pointing at
files that no longer exist, a scheme whose blueprint identifier no longer names
a target, a test plan that lost a target, and the build settings the spec pins
by name (macOS 11.0 floor, both architectures, no Mac Catalyst).

Run it from the repository root:

    Scripts/check-project-integrity.py
"""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECT = REPO_ROOT / "MacDirStat.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEME_DIR = PROJECT / "xcshareddata" / "xcschemes"
TEST_PLAN_DIR = REPO_ROOT / "TestPlans"

OBJECT_ID = re.compile(r"^[0-9A-F]{24}$")

# The six test targets of the verification contract (spec §9.1).
PACKAGE_TEST_TARGETS = {
    "Packages/ScanCore": ["ScanCoreTests", "ScanCoreFileSystemTests"],
    "Packages/TreemapLayout": ["TreemapLayoutTests"],
}
PROJECT_TEST_TARGETS = ["MacDirStatTests", "MacDirStatUITests", "MacDirStatPerformanceTests"]

SHARED_SCHEMES = [
    "MacDirStat",
    "MacDirStat-CI",
    "MacDirStat-Performance",
    "MacDirStat-CompatibilitySmoke",
]

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def load_pbxproj() -> dict:
    """Parse the old-style plist through plutil, which is also a syntax check."""
    try:
        raw = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(PBXPROJ)],
            check=True,
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError as error:
        print(f"error: {PBXPROJ} is not a readable property list:")
        print(error.stderr.decode().strip())
        sys.exit(1)
    return json.loads(raw)


def check_object_graph(objects: dict) -> None:
    for identifier in objects:
        if not OBJECT_ID.match(identifier):
            fail(f"object id {identifier!r} is not 24 uppercase hex characters")

    def referenced_ids(value) -> list[str]:
        if isinstance(value, str):
            return [value] if OBJECT_ID.match(value) else []
        if isinstance(value, list):
            return [found for item in value for found in referenced_ids(item)]
        if isinstance(value, dict):
            return [found for item in value.values() for found in referenced_ids(item)]
        return []

    for identifier, obj in objects.items():
        for reference in referenced_ids(obj):
            if reference not in objects:
                isa = obj.get("isa", "?")
                fail(f"{isa} {identifier} references unknown object {reference}")

    reachable = {identifier for obj in objects.values() for identifier in referenced_ids(obj)}
    root = load_pbxproj().get("rootObject")
    for identifier, obj in objects.items():
        if identifier not in reachable and identifier != root:
            fail(f"{obj.get('isa', '?')} {identifier} is unreachable from the project object")


def resolve_group_paths(objects: dict, group_id: str, prefix: Path) -> dict[str, Path]:
    """Maps each PBXFileReference id to its on-disk path."""
    resolved: dict[str, Path] = {}
    group = objects[group_id]
    here = prefix / group["path"] if group.get("path") else prefix

    for child_id in group.get("children", []):
        child = objects[child_id]
        if child["isa"] == "PBXGroup":
            resolved.update(resolve_group_paths(objects, child_id, here))
        elif child["isa"] == "PBXFileReference":
            if child.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                continue  # A build product; it does not exist until a build runs.
            resolved[child_id] = here / child["path"]
    return resolved


def check_file_references(objects: dict, project: dict) -> None:
    resolved = resolve_group_paths(objects, project["mainGroup"], REPO_ROOT)
    for identifier, path in resolved.items():
        if not path.exists():
            fail(f"file reference {identifier} points at missing {path.relative_to(REPO_ROOT)}")

    referenced_names = {path.name for path in resolved.values()}
    on_disk = {
        path.name
        for path in (REPO_ROOT / "App").rglob("*")
        if path.is_file() and path.suffix in {".swift", ".plist"}
    }
    for name in sorted(on_disk - referenced_names):
        fail(f"App/**/{name} exists on disk but no target compiles it")


def settings_for(objects: dict, configuration_list_id: str) -> dict[str, dict]:
    return {
        objects[config_id]["name"]: objects[config_id]["buildSettings"]
        for config_id in objects[configuration_list_id]["buildConfigurations"]
    }


def check_build_settings(objects: dict, project: dict, targets: dict[str, dict]) -> None:
    project_settings = settings_for(objects, project["buildConfigurationList"])

    for name, settings in project_settings.items():
        if settings.get("MACOSX_DEPLOYMENT_TARGET") != "11.0":
            fail(f"project {name}: MACOSX_DEPLOYMENT_TARGET must be 11.0 (spec §4.2)")
        architectures = settings.get("ARCHS", "").split()
        if sorted(architectures) != ["arm64", "x86_64"]:
            fail(f"project {name}: ARCHS must be 'arm64 x86_64' (spec §4.2), found {architectures}")
        if settings.get("SUPPORTS_MACCATALYST") != "NO":
            fail(f"project {name}: SUPPORTS_MACCATALYST must be NO (spec §4.2)")
        if settings.get("SDKROOT") != "macosx":
            fail(f"project {name}: SDKROOT must be macosx")
        if settings.get("SWIFT_VERSION") is None:
            fail(f"project {name}: SWIFT_VERSION is unset")

    if project_settings["Release"].get("ONLY_ACTIVE_ARCH") != "NO":
        fail("project Release: ONLY_ACTIVE_ARCH must be NO so Release builds both slices (spec §4.2)")

    app = targets["MacDirStat"]
    if app["productType"] != "com.apple.product-type.application":
        fail("MacDirStat must be an application target")
    app_settings = settings_for(objects, app["buildConfigurationList"])
    for name, settings in app_settings.items():
        info_plist = settings.get("INFOPLIST_FILE")
        if not info_plist or not (REPO_ROOT / info_plist).exists():
            fail(f"MacDirStat {name}: INFOPLIST_FILE {info_plist!r} is missing")

    for name in PROJECT_TEST_TARGETS:
        if name not in targets:
            fail(f"target {name} is missing (spec §9.1)")
            continue
        expected = (
            "com.apple.product-type.bundle.ui-testing"
            if name.endswith("UITests")
            else "com.apple.product-type.bundle.unit-test"
        )
        if targets[name]["productType"] != expected:
            fail(f"{name} has product type {targets[name]['productType']}, expected {expected}")

    for storyboard_setting in ("INFOPLIST_KEY_NSMainStoryboardFile", "INFOPLIST_KEY_NSMainNibFile"):
        for name, settings in app_settings.items():
            if storyboard_setting in settings:
                fail(f"MacDirStat {name}: {storyboard_setting} set — the lifecycle is programmatic (spec §4.1)")

    info_plist_path = REPO_ROOT / app_settings["Release"]["INFOPLIST_FILE"]
    with info_plist_path.open("rb") as handle:
        info = plistlib.load(handle)
    if "NSMainStoryboardFile" in info or "NSMainNibFile" in info:
        fail(f"{info_plist_path.name} names a storyboard/nib — the lifecycle is programmatic (spec §4.1)")
    if info.get("NSPrincipalClass") != "NSApplication":
        fail(f"{info_plist_path.name}: NSPrincipalClass must be NSApplication")
    if info.get("LSMinimumSystemVersion") != "$(MACOSX_DEPLOYMENT_TARGET)":
        fail(f"{info_plist_path.name}: LSMinimumSystemVersion must track MACOSX_DEPLOYMENT_TARGET")


def check_packages(objects: dict, project: dict) -> None:
    local_packages = [
        objects[identifier]["relativePath"]
        for identifier in project.get("packageReferences", [])
        if objects[identifier]["isa"] == "XCLocalSwiftPackageReference"
    ]
    for expected in PACKAGE_TEST_TARGETS:
        if expected not in local_packages:
            fail(f"the project does not reference the local package {expected} (spec §4.2)")

    for package, test_targets in PACKAGE_TEST_TARGETS.items():
        manifest = REPO_ROOT / package / "Package.swift"
        if not manifest.exists():
            fail(f"{package}/Package.swift is missing")
            continue
        text = manifest.read_text()
        for target in test_targets:
            if f'.testTarget(name: "{target}"' not in text:
                fail(f"{package} does not declare test target {target} (spec §9.1)")

    product_names = {
        obj["productName"]
        for obj in objects.values()
        if obj.get("isa") == "XCSwiftPackageProductDependency"
    }
    for expected in ("ScanCore", "TreemapLayout"):
        if expected not in product_names:
            fail(f"the app target does not depend on the {expected} package product (spec §4.2)")


def check_schemes(targets_by_id: dict[str, str]) -> None:
    for scheme in SHARED_SCHEMES:
        path = SCHEME_DIR / f"{scheme}.xcscheme"
        if not path.exists():
            fail(f"shared scheme {scheme} is missing (spec §9.1)")
            continue

        tree = ElementTree.parse(path)
        for reference in tree.iter("BuildableReference"):
            blueprint = reference.get("BlueprintIdentifier")
            if blueprint not in targets_by_id:
                fail(f"{scheme}: BuildableReference points at unknown target {blueprint}")
            elif reference.get("BlueprintName") != targets_by_id[blueprint]:
                fail(
                    f"{scheme}: BuildableReference names {reference.get('BlueprintName')} "
                    f"but {blueprint} is {targets_by_id[blueprint]}"
                )

        for plan_reference in tree.iter("TestPlanReference"):
            location = plan_reference.get("reference", "")
            plan_path = REPO_ROOT / location.removeprefix("container:")
            if not plan_path.exists():
                fail(f"{scheme}: test plan {location} does not exist")

    performance = ElementTree.parse(SCHEME_DIR / "MacDirStat-Performance.xcscheme")
    test_action = performance.find("TestAction")
    if test_action is None or test_action.get("buildConfiguration") != "Release":
        fail("MacDirStat-Performance must test in Release configuration (spec §9.1)")


def check_test_plans(targets: dict[str, dict]) -> None:
    plans = {}
    for path in sorted(TEST_PLAN_DIR.glob("*.xctestplan")):
        try:
            plans[path.stem] = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            fail(f"{path.name} is not valid JSON: {error}")

    for name in ("CI", "CI-ThreadSanitizer", "Performance", "CompatibilitySmoke"):
        if name not in plans:
            fail(f"test plan {name}.xctestplan is missing (spec §9.1)")

    def target_names(plan: dict) -> list[str]:
        return [entry["target"]["name"] for entry in plan.get("testTargets", [])]

    def validate_containers(name: str, plan: dict) -> None:
        for entry in plan.get("testTargets", []):
            target = entry["target"]
            container = target["containerPath"].removeprefix("container:")
            if container == "MacDirStat.xcodeproj":
                identifier = target["identifier"]
                match = [t for t in targets.values() if t["id"] == identifier]
                if not match:
                    fail(f"{name}: test target {target['name']} has unknown identifier {identifier}")
                elif match[0]["name"] != target["name"]:
                    fail(f"{name}: {identifier} is {match[0]['name']}, not {target['name']}")
            else:
                if container not in PACKAGE_TEST_TARGETS:
                    fail(f"{name}: unknown package container {container}")
                elif target["name"] not in PACKAGE_TEST_TARGETS[container]:
                    fail(f"{name}: {container} declares no test target {target['name']}")

    for name, plan in plans.items():
        validate_containers(name, plan)

    if "CI" in plans:
        expected = {
            "ScanCoreTests",
            "ScanCoreFileSystemTests",
            "TreemapLayoutTests",
            "MacDirStatTests",
            "MacDirStatUITests",
        }
        found = set(target_names(plans["CI"]))
        if found != expected:
            fail(
                "CI.xctestplan must hold every target except performance (spec §9.1); "
                f"missing {sorted(expected - found)}, unexpected {sorted(found - expected)}"
            )

    if "CI-ThreadSanitizer" in plans:
        if not plans["CI-ThreadSanitizer"]["defaultOptions"].get("threadSanitizerEnabled"):
            fail("CI-ThreadSanitizer.xctestplan does not enable the thread sanitizer (spec §9.1)")
        if set(target_names(plans["CI-ThreadSanitizer"])) != set(target_names(plans.get("CI", {}))):
            fail("CI-ThreadSanitizer.xctestplan must cover the same targets as CI.xctestplan")

    if "Performance" in plans:
        if target_names(plans["Performance"]) != ["MacDirStatPerformanceTests"]:
            fail("Performance.xctestplan must hold only MacDirStatPerformanceTests (spec §9.1)")
        options = plans["Performance"]["defaultOptions"]
        if options.get("threadSanitizerEnabled") or options.get("addressSanitizer", {}).get("enabled"):
            fail("Performance.xctestplan must run without sanitizers (spec §9.1)")

    if "CompatibilitySmoke" in plans:
        if target_names(plans["CompatibilitySmoke"]) != ["MacDirStatUITests"]:
            fail("CompatibilitySmoke.xctestplan must run the UI test target (spec §9.1)")


def main() -> int:
    document = load_pbxproj()
    objects = document["objects"]
    project = objects[document["rootObject"]]

    targets: dict[str, dict] = {}
    targets_by_id: dict[str, str] = {}
    for identifier in project["targets"]:
        target = objects[identifier]
        target["id"] = identifier
        targets[target["name"]] = target
        targets_by_id[identifier] = target["name"]

    check_object_graph(objects)
    check_file_references(objects, project)
    check_build_settings(objects, project, targets)
    check_packages(objects, project)
    check_schemes(targets_by_id)
    check_test_plans(targets)

    if problems:
        for problem in problems:
            print(f"error: {problem}")
        print(f"\nProject integrity check failed: {len(problems)} problem(s).")
        return 1

    print(
        "Project integrity check passed: "
        f"{len(targets)} targets, {len(SHARED_SCHEMES)} shared schemes, "
        f"{len(list(TEST_PLAN_DIR.glob('*.xctestplan')))} test plans, "
        "floor 11.0, universal, no Mac Catalyst."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
