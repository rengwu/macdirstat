#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
version=${VERSION:-}
build_number=${BUILD_NUMBER:-1}
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo 'Set VERSION to a three-part version, for example VERSION=1.0.0.' >&2
    exit 1
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo 'BUILD_NUMBER must be a positive integer.' >&2
    exit 1
fi

# Keep packaging builds separate from the local debug/test app.
derived=.build/release
products="$derived/Build/Products/Release"
app="$products/MacDirStat.app"
binary="$app/Contents/MacOS/MacDirStat"
plist="$app/Contents/Info.plist"
output="$PWD/dist"
archive="MacDirStat-$version-macos-universal.zip"
symbols="MacDirStat-$version-debug-symbols.zip"

xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO

[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" == "$build_number" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist")" == '14.0' ]]
lipo "$binary" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$app"
cmp LICENSE "$app/Contents/Resources/LICENSE"

mkdir -p "$output"
staging=$(mktemp -d "$PWD/.build/release-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT

ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive"
ditto -c -k --sequesterRsrc --keepParent "$products/MacDirStat.app.dSYM" "$staging/$symbols"
# Validate the app as users receive it, including its signature and executable.
ditto -x -k "$staging/$archive" "$staging/unpacked"
codesign --verify --deep --strict "$staging/unpacked/MacDirStat.app"
cmp "$binary" "$staging/unpacked/MacDirStat.app/Contents/MacOS/MacDirStat"

commit=$(git rev-parse HEAD)
cat > "$staging/RELEASE_NOTES.md" <<NOTES
## MacDirStat $version

Native, read-only disk visualization for macOS 14 Sonoma or later.
The app ZIP includes both Apple Silicon and Intel builds.

### Install

Download \`$archive\`, extract it, and drag MacDirStat.app to Applications.
The debug-symbols ZIP is for diagnosing crashes and is not needed to run the app.

**This build is ad hoc signed, not Developer ID signed or notarized.**
macOS may block the downloaded app. See [Apple's instructions for opening an app
from an unidentified developer](https://support.apple.com/guide/mac-help/mh40616/mac).
Building from source is also supported; see the repository README.

### Verify the download

Download SHA256SUMS.txt and both ZIPs into the same folder, then run:

\`\`\`sh
shasum -a 256 -c SHA256SUMS.txt
\`\`\`

### Build details

- Version: $version (build $build_number)
- Source commit: $commit
- Signing: ad hoc; notarization pending
- License: MIT (included in the app)

### Changes

Review the generated changes below before publishing this draft.
NOTES
cp "$staging/$archive" "$staging/$symbols" "$staging/RELEASE_NOTES.md" "$output/"
(
    cd "$output"
    shasum -a 256 "$archive" "$symbols" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
echo "Release files are ready in $output"
