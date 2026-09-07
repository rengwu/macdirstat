# Releasing MacDirStat

The GitHub workflows can test, build, and package a release without a paid Apple
Developer account. Releases remain **draft prereleases** until a maintainer
reviews and publishes them. These builds are ad hoc signed and **not notarized**;
GitHub Releases does not replace Apple's signing and notarization process.

## What runs

- **CI** runs `make test` on Apple Silicon and Intel macOS 15 runners for pushes
  to `main` and pull requests. It can also be run manually.
- **Release** runs the same tests, then builds a universal Release app with
  Xcode 26.3. It verifies both architectures, the bundle version, the embedded
  MIT license, and the ad hoc signature, including after extracting the ZIP.
- The version comes from the workflow input or tag. The GitHub workflow run
  number becomes the app's build number; the project file does not need a version
  edit for every release.
- Build jobs have read-only repository access. Only the draft-release job gets
  permission to write releases. No additional GitHub or Apple secrets are needed.

The workflow stores these files as a `release-files` artifact for 14 days:

| File | Purpose |
| --- | --- |
| `MacDirStat-X.Y.Z-macos-universal.zip` | The app for Apple Silicon and Intel |
| `MacDirStat-X.Y.Z-debug-symbols.zip` | Matching dSYM files for crash diagnosis |
| `SHA256SUMS.txt` | SHA-256 checksums for both ZIPs |
| `RELEASE_NOTES.md` | Installation, signing status, and source commit |

The draft release receives both ZIPs and the checksum file, with installation
notes and GitHub-generated changes in its description.

## Validate packaging without creating a release

Open [Actions → Release](https://github.com/rengwu/macdirstat/actions/workflows/release.yml),
choose **Run workflow**, select the branch, enter a version such as `1.0.0`, and
uncheck **Create a draft prerelease**. This runs the entire test and packaging
process and uploads workflow artifacts without creating a release or tag.

The CLI equivalent is:

```sh
gh workflow run release.yml --ref main -f version=1.0.0 -F create_draft=false
gh run list --workflow release.yml
```

Open the completed run to download its `release-files` artifact. The app is
inside the versioned ZIP; keep that ZIP intact when transferring it between Macs.

## Prepare a draft

Use the same **Run workflow** form with **Create a draft prerelease** checked.
Choose the branch or tag containing the exact code you intend to release.

```sh
gh workflow run release.yml --ref main -f version=1.0.0 -F create_draft=true
```

Alternatively, tag the intended commit and push that tag:

```sh
git tag -a v1.0.0 -m 'MacDirStat 1.0.0'
git push origin v1.0.0
```

Versions must be three non-negative numbers with no leading zeros, such as
`1.0.0`. Tags must use the matching `v1.0.0` form. An existing tag must point at
the same commit the workflow built. Existing releases are not overwritten.
Concurrent runs for the same version wait for one another.

If packaging fails, fix the failure and rerun. If creating a release fails after
an earlier attempt already created its draft, inspect that draft before doing
anything else; the workflow deliberately does not replace its assets. After a
release is published, use a new version for changes.

## Review and publish

1. Download the app ZIP from the draft and verify its checksum. Check the version
   in About MacDirStat and confirm it launches from Applications.
2. Smoke-test a small folder, Fast mode, cancellation, selection, Open, and Reveal
   in Finder. Check incomplete results and keyboard navigation. Test the same
   artifact on macOS 14 and a current supported macOS version when hosts are
   available; CI on macOS 15 is not a substitute for that compatibility check.
3. Edit the generated release notes into a concise description of changes and
   known limitations. Keep the unsigned/notarized status accurate.
4. Publish the draft manually when ready. Keep the prerelease label while the
   build is intended for early testing. Repository visibility is a separate
   setting: releases in a private repository are only available to people with
   repository access.
5. Once there is a public download, update the README's **Get started** section
   with that release and its installation instructions.

GitHub never automatically publishes the drafts this workflow creates.

## Build the same package locally

```sh
make test
VERSION=1.0.0 BUILD_NUMBER=1 make package
cd dist
shasum -a 256 -c SHA256SUMS.txt
```

The packaging build uses `.build/release` and writes artifacts to `dist/`, both
Git-ignored. It explicitly builds both architectures. This command packages the
working tree; commit the intended source before using its recorded commit as
release provenance. Local output for the same version is replaced on a rerun.

## When Developer ID signing is available

The current script explicitly uses an ad hoc identity. To ship notarized builds,
add Developer ID signing with hardened runtime, submit the app to Apple's notary
service, and staple the ticket **before** creating and hashing the final ZIP.
Update the release notes to describe the verified signing state. Store signing
credentials in GitHub secrets and expose them only to the release build.

## References

- [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub runner images and Xcode versions](https://github.com/actions/runner-images)
- [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create)
