# Releasing Voxum

Voxum updates itself with [Sparkle 2](https://sparkle-project.org). Every installed copy reads the
appcast at `https://github.com/GSB05BR/voxum/releases/latest/download/appcast.xml` (`SUFeedURL` in
`Resources/Info.plist`) once a day, unless the user turned automatic checks off. It installs an update only
when the zip carries a valid EdDSA signature for the public key built into the app (`SUPublicEDKey`).
The signature is checked before the archive is unpacked (`SUVerifyUpdateBeforeExtraction`).

The Sparkle tools come with the SwiftPM package. After `swift package resolve --disable-keychain`
they are in `.build/artifacts/sparkle/Sparkle/bin/` (`generate_keys`, `sign_update`, …). The
commands below use the short name `bin/` for that folder.

**Always pass `--disable-keychain` to `swift` commands** (`swift build`, `swift test`, `swift run`,
`swift package resolve`). Every dependency is public. Without that flag, SwiftPM looks up github.com
credentials in the Keychain, which shows a "swift-package wants to use your confidential information"
dialog and can hold the build until the dialog is answered. `scripts/build-app.sh` and
`scripts/check-strings.sh` already pass it.

## One-time setup: the update signing key

The key lives under its own Keychain account, `voxum`, so it is never shared with another Sparkle app
(Sparkle's default account, `ed25519`, is shared by every Sparkle project of the same user).
`scripts/release.sh` uses that account. Set `SPARKLE_ACCOUNT` to use another one.

1. Create the key pair:

       bin/generate_keys --account voxum

   The private key goes into your **login Keychain** (an item named "Private key for signing Sparkle
   updates", account `voxum`). It is never written to the repository or anywhere else on disk. The
   command prints the **public** key. Running it again only prints the existing public key; it does not
   make a new one. `bin/generate_keys -p --account voxum` prints the public key and never creates one.
2. Paste the public key into `Resources/Info.plist`, replacing the placeholder
   `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`:

       <key>SUPublicEDKey</key><string>…the base64 public key…</string>

   Commit it. The public key is not a secret. While the placeholder is there, the app never starts the
   updater, and `scripts/build-app.sh --release` and `scripts/release.sh` refuse to build a release.
3. **Never commit the private key**, and never export it into the repository folder.

### Back up the private key

If the private key is lost, no installed copy will ever accept another update: users would have to
download a new version by hand. Export a backup once and keep it somewhere safe, **outside the
repository**, such as an encrypted external drive or a password manager's secure file:

    bin/generate_keys --account voxum -x ~/somewhere-safe/voxum-sparkle-private-key

To use the key on another Mac, import it into that Mac's login Keychain:

    bin/generate_keys --account voxum -f ~/somewhere-safe/voxum-sparkle-private-key

Delete any temporary copy of the exported file once it is stored safely.

## Signing identity

Every release must be signed with **one and the same** code-signing identity: `CODESIGN_IDENTITY` in
the git-ignored `scripts/local.env` (see `docs/BUILD.md`). macOS ties the Microphone and
Accessibility permissions to that signature. If the identity changes, every user must grant both
permissions again after the update, and dictation stops pasting until they do.

`scripts/release.sh` refuses ad-hoc signing (`-`): an ad-hoc signature changes with every build, so
macOS would ask for both permissions again after every update. Before building, it shows the
certificate's common name and organizational unit (team) and asks for `y`. Pass `--yes` to skip the
question.

The certificate is **visible to anyone** who downloads the release (`codesign -dvv Voxum.app`). Published
releases are therefore signed with a **self-signed code-signing certificate named "Voxum"**, created by
the maintainer. It carries no personal data. They are never signed with a personal Apple certificate:
an "Apple Development" certificate carries its owner's Apple ID e-mail and team ID. Ad-hoc signing is
refused, as described above.

- To create such a certificate, use Keychain Access › Certificate Assistant › Create a Certificate, with
  type "Code Signing" and a long validity. It gives a stable signature, so the permissions survive updates.
  Gatekeeper treats it like any other certificate without notarization (see "Not notarized" below).
- Back it up next to the Sparkle key. It does not need to be trusted: `security find-identity -p codesigning`
  lists it as `CSSMERR_TP_NOT_TRUSTED`, and `codesign` and `scripts/release.sh` sign with it all the same.
  The first `codesign` run asks for access to its private key: choose "Always Allow".
- Keep the same certificate for every release.

## Versions

- `CFBundleShortVersionString` is the version people see (`1.2.3`).
- `CFBundleVersion` is the build number: an integer that only goes up. Sparkle compares it
  (`sparkle:version` in the appcast) to decide whether an update is newer. Never reuse or lower it.

`scripts/release.sh <x.y.z>` sets the version. It adds 1 to the build number when the version changes,
and keeps the build number when the same version is rebuilt. Before building, it reads the live
appcast and refuses a build number that is not greater than the published one. This catches a stale
checkout. A real release also stops when the appcast cannot be read (no answer within 20 s, an
error status, invalid XML, or no `sparkle:version` in it); a dry run only warns. It also refuses when the tag `v<x.y.z>` exists locally or on GitHub, or when the GitHub release
already exists.

## Release steps

1. Write the release notes in `docs/release-notes/<x.y.z>.md` (Markdown). Sparkle shows them in its
   update window, and they become the GitHub release notes. Without the file, the appcast says only
   "Voxum x.y.z".
2. Rehearse without the key:

       bash scripts/release.sh <x.y.z> --dry-run

   It builds `build/release/Voxum-<x.y.z>.zip` and `build/release/appcast.xml` **without an EdDSA
   signature**, prints a warning, and puts `Resources/Info.plist` back as it was. `--skip-sign` is an
   alias. These files must never be published, and `--publish` refuses to run together with either flag.
   In a dry run, the GitHub checks only warn when they cannot run (for example, offline).
3. Build the real release:

       bash scripts/release.sh <x.y.z>

   Before building, it checks:
   - that `SUPublicEDKey` is a valid key **and** equals the public key of the Keychain key
     (`generate_keys -p --account voxum`, which only reads; if it fails, the script shows the tool's own
     message, and only "No existing signing key found" means there is no key);
   - the signing identity (shown, then confirmed);
   - the published appcast, the tag and the release (see "Versions").

   It then:
   - bumps `Resources/Info.plist`;
   - builds with `scripts/build-app.sh --release`, which embeds `Sparkle.framework` and signs it inside out;
   - zips the app with `ditto -c -k --keepParent` and checks that the unpacked copy still passes
     `codesign --verify --deep --strict`;
   - signs the zip with `sign_update --account voxum` (macOS may ask you to allow access to the key), and
     verifies that signature;
   - writes the appcast with `sparkle:minimumSystemVersion` 14.0 and checks it with `xmllint`.

   The enclosure URL is `https://github.com/GSB05BR/voxum/releases/download/v<x.y.z>/Voxum-<x.y.z>.zip`.
4. Commit the version bump (`Resources/Info.plist`) and the release notes, then push.
5. Publish:

       bash scripts/release.sh <x.y.z> --publish

   Run it from the checkout whose HEAD is pushed to `GSB05BR/voxum`. It first checks four things:
   - the Info.plist is already at `<x.y.z>`;
   - the working tree is clean;
   - HEAD exists in `GSB05BR/voxum` (checked with `gh api`);
   - everything listed in step 3.

   Then it rebuilds and signs with the same build number, and runs `gh release create v<x.y.z>` on HEAD
   with the zip and `appcast.xml` attached.
6. Check the result:
   - `curl -sL https://github.com/GSB05BR/voxum/releases/latest/download/appcast.xml` should show the
     new version.
   - On a Mac with an older version installed, "Check now" should offer the update.

The appcast lists only the newest release. The feed URL always serves the appcast of the
**latest** GitHub release, so a release marked as a draft or pre-release is never offered to users.

### If publishing stops halfway

If `gh release create` fails after creating the release (for example, during an upload), the release
exists but is incomplete. Running `--publish` again then stops before building, usually at "the tag
v<x.y.z> already exists on github.com/GSB05BR/voxum" (`gh release create` makes the tag first). If
`appcast.xml` was already uploaded to a release marked latest, it stops even earlier, at "build N is not
greater than the published build N": in that case, do not bump the build number. Either:

- upload the missing files to it: `gh release upload v<x.y.z> build/release/Voxum-<x.y.z>.zip build/release/appcast.xml --repo GSB05BR/voxum --clobber`; or
- delete that release and its tag on GitHub (web page, or `gh release delete v<x.y.z> --cleanup-tag`),
  then run `--publish` again.

### Signed appcast: not used (for now)

Sparkle can also sign the appcast itself (`SURequireSignedFeed`). Voxum does not use it. The zip is
already EdDSA-signed and served over HTTPS, so a signed feed would only protect the feed's metadata
(notes, minimum macOS) from someone with write access to the repository but not the key. Adopting it
later takes three things: `SURequireSignedFeed` in the Info.plist, `sign_update --account voxum appcast.xml`
after the appcast is written, and `sign_update --verify` before publishing. A copy that requires a
signed feed rejects every unsigned appcast, so all three must ship together.

## Not notarized: the first install

Voxum has no paid Apple Developer account, and therefore no Developer ID certificate and no
notarization. Gatekeeper blocks the first launch of a downloaded copy:

- Unpack the zip by **double-clicking it** (Archive Utility). Command-line `unzip` and some third-party
  tools drop a signature kept in extended attributes, and macOS then reports the app as damaged.
- **Right-click (or Control-click) Voxum.app → Open**, then **Open** in the dialog.
- On recent macOS versions the dialog may offer only "Done". In that case, open
  **System Settings › Privacy & Security** and click **Open Anyway** next to the message about Voxum.

This is needed once. Sparkle installs later updates after checking their EdDSA signature and clears the
download's quarantine flag, so updated versions open without the prompt.

## When updates are off

The window and the menu show the update controls disabled ("Updates are off in this build") when:

- `SUPublicEDKey` is still the placeholder (or is not a valid key);
- `VOXUM_DATA_DIR` is set (a development run);
- the app runs unbundled (`swift run`).

In those cases Sparkle is never started, so nothing is checked, downloaded or written.

## Scheduled checks in a menu-bar app

When a daily check finds an update while Voxum is not in front, Sparkle does not open its window behind
other apps. Instead, the menu-bar icon gets a badge, and an "Update available: Voxum x.y.z…" item
appears at the top of the menu and in the main window. Clicking it opens Sparkle's update window. The
reminder goes away once the update is seen or the session ends. "Check now" always opens the window
directly.
