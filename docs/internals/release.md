# CI and releases

Two workflows in `.github/workflows/` build zslice: `ci.yml` for each push and pull request, and `release.yml` for each version tag. This page tells how to cut a release, and lists the secrets that the release needs.

## CI

`ci.yml` runs on a push to `main`, on each pull request, and by hand. A change of the docs or of Markdown files only does not start it. The first job compares the change with its base, and starts only the jobs that the change needs. A change of the core (`src/`, `include/`, `vendor/`, `tools/`, `build.zig`, or `ci.yml`) starts all jobs.

| Job | Runner | What it does |
|---|---|---|
| Core tests | Ubuntu | `zig build test`, then the command line tool slices a 20 mm cube. |
| Web app | Ubuntu | `zig build web`, then `test-node.mjs`, `test-link.mjs`, and `test-signing.mjs` in Node.js. |
| Linux app | Ubuntu 24.04 | The GTK 4 app with meson and ninja. A warning stops the build (`-Dwerror=true`). Then `meson test`. |
| Mac app | macOS | Checks that the Xcode project lists each Swift file, and builds the Xcode project (the core, the app, and the Quick Look extensions). Then the app opens a box, slices it, and writes a picture of its window. That last step does not fail the job yet. |
| Windows app | Windows | Only when `windows/` exists. The core and the link test for x64 and ARM64 (ARM64: build and link only), and the app with msbuild when `windows/` has a `.sln` or a `.vcxproj`. The ARM64 job adds the ARM64 tools of MSVC when the runner does not have them. |

`mlugg/setup-zig` keeps the Zig cache between runs. `tools/cube_stl.py` writes the test parts.

## Cut a release

1. Check that CI passes on `main`.
2. Tag the commit, and push the tag:

   ```sh
   git tag v0.6.0-beta
   git push origin v0.6.0-beta
   ```

3. Watch the `release` workflow in the Actions tab. The time of a run is not measured yet. Notarization alone can need some minutes.
4. Read the release page. The notes come from the commit subjects since the tag before.

To make the release of a tag again (for example after a failed job), run the `release` workflow by hand with the tag. The run replaces the files and the notes of the release.

### Tags and prereleases

The tag is `v` and the version: `v0.6.0-beta`. A tag has no counter such as `beta.2`.

| Tag | GitHub | Homebrew tap |
|---|---|---|
| `v0.6.0` | A release, the latest | Updated |
| `v0.6.0-beta` | A prerelease | Updated |
| `v0.6.0-rc1`, `v0.6.0-test`, any other suffix | A prerelease | Not changed |

While zslice is in beta, `-beta` is the usual release. Use another suffix to try the release workflow with no change to the tap.

### The files of a release

VERSION is the tag with no `v`.

| File | What it is |
|---|---|
| `zslice-VERSION-x86_64-linux-musl.tar.gz`, `zslice-VERSION-aarch64-linux-musl.tar.gz` | The command line tool for Linux (static). |
| `zslice-VERSION-aarch64-macos.tar.gz`, `zslice-VERSION-x86_64-macos.tar.gz` | The command line tool for macOS. |
| `zslice-VERSION-lib-aarch64-linux-gnu.tar.gz`, `zslice-VERSION-lib-x86_64-linux-gnu.tar.gz` | The C library (`libzslice.a` and the headers) for printer hosts. |
| `zslice-VERSION-macos-universal.dmg` | The Mac app for Apple silicon and Intel, signed with the Developer ID, notarized, and stapled. |
| `zslice-gtk-VERSION-linux-x86_64.tar.gz`, `zslice-gtk-VERSION-linux-aarch64.tar.gz` | The Linux app: `bin/zslice-gtk` and `share/`. It needs GTK 4.14 or later. |
| `zslice-VERSION-web.zip` | The web app: static files for a web server. |
| `zslice-VERSION-windows-x64.zip`, `zslice-VERSION-windows-arm64.zip` | The Windows app, when `windows/` exists. It is not signed. |
| `SHA256SUMS` | The SHA-256 of each file. Check a file with `sha256sum -c SHA256SUMS --ignore-missing`. |

The printdeck Action downloads the Linux tools by their names. Keep the names of the tool and library tarballs.

With no Apple secrets, the Mac app is signed ad hoc and is not notarized. Its file is then `zslice-VERSION-macos-universal-unsigned.dmg`, and the cask does not change.

The Windows app has no signature: there is no Windows certificate yet. SmartScreen shows a warning at the first start.

The Linux app is a tarball only. An AppImage needs a bundle of GTK 4, and the release does not make one yet.

### Homebrew

The `homebrew` job writes three files to [beetlebugorg/homebrew-tap](https://github.com/beetlebugorg/homebrew-tap) with `packaging/homebrew/tap.sh`:

- `Formula/zslice.rb`: the command line tool, from the tarballs of the release (macOS and Linux).
- `Formula/zslice-gtk.rb`: the Linux app, built from the source tarball of the tag with the `gtk4` of Homebrew and `zig@0.16`.
- `Casks/zslice.rb`: the Mac app, from the signed dmg.

The templates are `packaging/homebrew/*.rb.in`. `packaging/homebrew/tap/` has the formulas of v0.5.0-beta, for a first pull request to the tap.

## Secrets

Set each secret in the repository: Settings > Secrets and variables > Actions > New repository secret. Or use `gh secret set NAME -R beetlebugorg/zslice`, which reads the value from the terminal or from a file on standard input. The names are the same as in lookout-marine. GitHub does not show a secret again, so set each value again from its file.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | The Developer ID Application certificate and its private key: a `.p12` file, as base64. |
| `MACOS_CERT_PASSWORD` | The password of the `.p12` file. |
| `APPLE_TEAM_ID` | The team id of the Apple Developer account: ten characters. |
| `NOTARY_KEY_P8` | An App Store Connect API key: the full text of the `AuthKey_<id>.p8` file. |
| `NOTARY_KEY_ID` | The key id of that API key. |
| `NOTARY_ISSUER_ID` | The issuer id of the App Store Connect API keys. |
| `HOMEBREW_TAP_TOKEN` | A fine-grained GitHub token with write access to the contents of beetlebugorg/homebrew-tap only. |

With no Apple secrets, the release has an unsigned dmg. With no tap token, the tap does not change. The release is made in both cases.

### The Developer ID certificate

Only the Account Holder of the Apple Developer account can make a Developer ID certificate.

1. On a Mac, open Keychain Access. Select Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Enter your email, select "Saved to disk", and save the `.certSigningRequest` file.
2. At [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list), click +. Select **Developer ID Application** and the G2 Sub-CA. Upload the request, and download the `.cer` file.
3. Double-click the `.cer` file. Keychain Access adds it to the login keychain, with its private key.
4. In Keychain Access > My Certificates, right-click "Developer ID Application: NAME (TEAMID)", and select Export. Save as a `.p12` file, and give it a strong password.
5. Set the two secrets:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set MACOS_CERT_P12 -R beetlebugorg/zslice
   gh secret set MACOS_CERT_PASSWORD -R beetlebugorg/zslice
   ```

6. Delete the `.p12` file, or keep it in a safe place.

### The team id

The team id is on [developer.apple.com/account](https://developer.apple.com/account) > Membership details. It is also in the name of the certificate, in the parentheses.

```sh
gh secret set APPLE_TEAM_ID -R beetlebugorg/zslice
```

### The App Store Connect API key

notarytool sends the app to Apple with this key. It needs no Apple ID and no app password.

1. At [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), open Users and Access > Integrations > App Store Connect API > Team Keys. (The Account Holder must first request access to the API there.)
2. Click +. Give the key a name (for example "zslice notary"), and the role **Developer**. That role can notarize.
3. Download the `AuthKey_<id>.p8` file. Apple lets you download it one time only.
4. The key id is in the list of keys. The issuer id is above the list.
5. Set the three secrets:

   ```sh
   gh secret set NOTARY_KEY_P8 -R beetlebugorg/zslice < AuthKey_ABC123DEFG.p8
   gh secret set NOTARY_KEY_ID -R beetlebugorg/zslice
   gh secret set NOTARY_ISSUER_ID -R beetlebugorg/zslice
   ```

### The tap token

1. At [github.com/settings/personal-access-tokens](https://github.com/settings/personal-access-tokens/new), make a new fine-grained token.
2. Resource owner: beetlebugorg. Expiration: one year, or less.
3. Repository access: **Only select repositories**, and select beetlebugorg/homebrew-tap.
4. Permissions > Repository permissions > Contents: **Read and write**. GitHub adds Metadata (read) itself. Give no other permission.
5. Generate the token, and set it:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN -R beetlebugorg/zslice
   ```

Make a new token before the old one expires. The release log shows a warning when the token is not set.

## Make a release on a Mac by hand

`macos/release.sh` is the script of the Mac job. It needs a Developer ID identity in the keychain and the notary key:

```sh
export APPLE_TEAM_ID=ABCDE12345 NOTARY_KEY_FILE=~/keys/AuthKey_ABC123DEFG.p8
export NOTARY_KEY_ID=ABC123DEFG NOTARY_ISSUER_ID=...
macos/release.sh 0.6.0-beta 1    # macos/build/zslice-0.6.0-beta-macos-universal.dmg
```

With no `APPLE_TEAM_ID`, it makes an unsigned dmg. The bundle gets the version with no suffix (0.6.0), and the build number.
