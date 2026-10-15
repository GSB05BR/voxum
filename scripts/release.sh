#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a release of the app and its Sparkle appcast (spec §6; steps in docs/RELEASING.md).
#
#   bash scripts/release.sh <x.y.z>             build/release/<Name>-<x.y.z>.zip + appcast.xml, EdDSA-signed
#   bash scripts/release.sh <x.y.z> --publish   the same, then `gh release create v<x.y.z>` with both files
#   bash scripts/release.sh <x.y.z> --dry-run   rehearsal without the signing key (alias: --skip-sign):
#                                               UNSIGNED appcast, Info.plist restored afterwards; never publishable
#   --yes                                       sign with the identity shown without asking
#
# Versions: CFBundleShortVersionString becomes <x.y.z>; CFBundleVersion (the integer Sparkle
# compares) goes up by one whenever the version changes, and stays when <x.y.z> is rebuilt.
# The EdDSA private key stays in the login Keychain: sign_update reads it there, nothing is
# written to disk. The Sparkle tools come from the SwiftPM artifact (swift package resolve --disable-keychain).
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

VERSION="" PUBLISH=0 DRY_RUN=0 YES=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        --yes) YES=1 ;;
        --dry-run|--skip-sign) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must look like 1.2.3 (got '$VERSION')"
if [ "$PUBLISH" = 1 ] && [ "$DRY_RUN" = 1 ]; then
    die "--publish cannot be combined with --dry-run/--skip-sign: installed copies reject an unsigned update"
fi

PLIST=Resources/Info.plist
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
NAME="$(plist CFBundleExecutable)"
FEED="$(plist SUFeedURL)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"
# The repository comes from the feed URL: https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
REPO="$(sed -nE 's#^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$#\1#p' <<<"$FEED")"
[ -n "$REPO" ] || die "SUFeedURL in $PLIST is not a GitHub 'releases/latest/download/appcast.xml' URL: $FEED"
[ "$MIN_SYSTEM" = "14.0" ] || die "LSMinimumSystemVersion is '$MIN_SYSTEM'; the appcast states 14.0 (spec)"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
# The Keychain account of this app's EdDSA key (generate_keys/sign_update --account), so it is not
# shared with other Sparkle apps of the same user (their default account is "ed25519").
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-$(tr '[:upper:]' '[:lower:]' <<<"$NAME")}"
# Must match UpdateConfiguration.publicKeyPlaceholder (TranscricaoCore).
KEY_PLACEHOLDER="REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
command -v xmllint >/dev/null || die "xmllint not found"

warn_unsigned() {
    echo "" >&2
    echo "  ************************************************************************" >&2
    echo "  *  DRY RUN: the zip is NOT signed with EdDSA and the appcast has no    *" >&2
    echo "  *  sparkle:edSignature. Sparkle rejects it; never publish these files. *" >&2
    echo "  ************************************************************************" >&2
    echo "" >&2
}

# Signing identity: the one build-app.sh uses (CODESIGN_IDENTITY from the environment or the
# git-ignored scripts/local.env), exported so both scripts agree.
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -f scripts/local.env ]; then
    # shellcheck disable=SC1091
    source scripts/local.env
fi
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# Prints the certificate's common name and organizational unit (team) of CODESIGN_IDENTITY.
describe_identity() {
    local line hash
    # Not -v: a self-signed certificate is listed as CSSMERR_TP_NOT_TRUSTED, and codesign signs with it
    # fine. Expired or revoked identities are still refused.
    line="$(security find-identity -p codesigning | grep -F -- "$CODESIGN_IDENTITY" | grep -vE 'EXPIRED|REVOKED' | head -1 || true)"
    [ -n "$line" ] || die "no usable code-signing identity in the Keychain matches CODESIGN_IDENTITY"
    hash="$(awk '{print $2}' <<<"$line")"
    local subject
    subject="$( { security find-certificate -a -Z -p 2>/dev/null || true; } | awk -v h="$hash" '
        /^SHA-1 hash:/ { take = ($3 == h) }
        take && /BEGIN CERTIFICATE/ { pem = 1 }
        take && pem { print }
        take && /END CERTIFICATE/ { pem = 0; take = 0 }' \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -nE 's/^ *(commonName|organizationalUnitName) *= */  \1: /p' || true)"
    if [ -n "$subject" ]; then echo "$subject"; else echo "  $(sed -E 's/^ *[0-9]+\) *//' <<<"$line")"; fi
}

if [ "$DRY_RUN" = 1 ]; then
    warn_unsigned
    if [ "$CODESIGN_IDENTITY" = "-" ]; then echo "signing identity: ad-hoc (-)"; else echo "signing identity:"; describe_identity; fi
else
    KEY="$(plist SUPublicEDKey)"
    if [ -z "$KEY" ] || [ "$KEY" = "$KEY_PLACEHOLDER" ]; then
        die "SUPublicEDKey in $PLIST is empty or the placeholder: run generate_keys and paste the public key (docs/RELEASING.md)"
    fi
    # Same rule as UpdateConfiguration.isValidPublicKey: a malformed key ships an app whose updater never starts.
    [[ "$KEY" =~ ^[A-Za-z0-9+/]+=*$ ]] && [ "$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
        || die "SUPublicEDKey in $PLIST is not an EdDSA public key (base64 of 32 bytes)"
    [ -x "$SIGN_UPDATE" ] && [ -x "$GENERATE_KEYS" ] \
        || die "Sparkle's tools are missing in $SPARKLE_BIN: run 'swift package resolve --disable-keychain' first"
    # The key in the app must be the one that signs: a mismatch makes every later update fail on
    # installed copies. -p only looks the existing key up and prints its public half. Its failures
    # (missing key, access denied, cancelled, corrupt item) are printed on stdout: report them as they are.
    KEYS_ERR="$(mktemp)"
    if ! KEYCHAIN_KEY="$("$GENERATE_KEYS" -p --account "$SPARKLE_ACCOUNT" 2>"$KEYS_ERR")"; then
        KEYS_MSG="$(printf '%s %s' "$KEYCHAIN_KEY" "$(cat "$KEYS_ERR")" | tr '\n' ' ' | sed -E 's/ +/ /g; s/^ //; s/ $//')"
        rm -f "$KEYS_ERR"
        die "generate_keys -p could not read the Sparkle signing key for account '$SPARKLE_ACCOUNT' from the login Keychain: ${KEYS_MSG:-no output}. Only a missing key needs a new one; for any other error fix the Keychain item instead (docs/RELEASING.md)"
    fi
    rm -f "$KEYS_ERR"
    [ "$KEYCHAIN_KEY" = "$KEY" ] \
        || die "SUPublicEDKey in $PLIST is not the public key of the Keychain key (account '$SPARKLE_ACCOUNT')"
    # Ad-hoc signatures change with every build: macOS would ask again for Microphone and
    # Accessibility after every update.
    [ "$CODESIGN_IDENTITY" != "-" ] \
        || die "releases are not signed ad-hoc: set CODESIGN_IDENTITY in scripts/local.env (docs/RELEASING.md)"
    echo "signing identity (every release must use the same one; it is visible in the published app):"
    describe_identity
    if [ "$YES" != 1 ]; then
        [ -t 0 ] || die "not interactive: pass --yes to sign with this identity"
        read -r -p "Sign the release with this identity? [y/N] " answer
        [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "cancelled"
    fi
fi
if [ "$PUBLISH" = 1 ]; then
    command -v gh >/dev/null || die "gh (GitHub CLI) not found"
    # The published build must be the committed one: commit (and push) the version bump first.
    [ "$(plist CFBundleShortVersionString)" = "$VERSION" ] \
        || die "Info.plist is not at $VERSION yet: run 'scripts/release.sh $VERSION' first, then commit and push the bump"
    [ -z "$(git status --porcelain)" ] || die "the working tree has changes: commit them before publishing"
    # The tag goes on HEAD, which must exist in the public repository itself (not only in another remote).
    gh api "repos/$REPO/commits/$(git rev-parse HEAD)" --silent 2>/dev/null \
        || die "HEAD ($(git rev-parse --short HEAD)) is not on github.com/$REPO: push it there before publishing"
fi

# 1. Versions: the next build number (written below, after the checks).
CURRENT_VERSION="$(plist CFBundleShortVersionString)"
CURRENT_BUILD="$(plist CFBundleVersion)"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion must be an integer (got '$CURRENT_BUILD')"
if [ "$CURRENT_VERSION" = "$VERSION" ]; then
    BUILD="$CURRENT_BUILD"
else
    if [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
        die "$VERSION is older than the current version $CURRENT_VERSION"
    fi
    BUILD=$((CURRENT_BUILD + 1))
fi

# What is already published (read-only). A conflict always stops; a check that cannot run stops a
# real release and only warns in a dry run.
cannot_check() { if [ "$DRY_RUN" = 1 ]; then echo "warning: $* (dry run: continuing)" >&2; else die "$*"; fi; }
# The live appcast: every installed copy compares this build number with what it already has, so
# the new one must be greater than any published (a stale checkout would reuse one).
LIVE="$(mktemp)"
STATUS="$(curl -sSL --connect-timeout 10 --max-time 20 -o "$LIVE" -w '%{http_code}' "$FEED" 2>/dev/null || true)"
case "$STATUS" in
    200)
        xmllint --noout "$LIVE" 2>/dev/null || cannot_check "the published appcast ($FEED) is not valid XML"
        PUBLISHED="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>|sparkle:version="[0-9]+"' "$LIVE" \
            | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
        # A feed that answers but names no build cannot be compared: stop instead of skipping the check.
        if [ -z "$PUBLISHED" ]; then
            rm -f "$LIVE"
            cannot_check "the published appcast ($FEED) has no sparkle:version this script can read"
        elif [ "$BUILD" -le "$PUBLISHED" ]; then
            rm -f "$LIVE"
            die "build $BUILD is not greater than the published build $PUBLISHED: update this checkout's Resources/Info.plist, or, if this release was partially published, see 'If publishing stops halfway' in docs/RELEASING.md"
        fi
        echo "published appcast: build ${PUBLISHED:-none (dry run)}" ;;
    404) echo "published appcast: none yet (404)" ;;
    *) cannot_check "could not read the published appcast $FEED (HTTP ${STATUS:-error})" ;;
esac
rm -f "$LIVE"
# The tag and the GitHub release must not exist yet (gh release create would attach the new zip
# to an existing tag's older commit).
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "the tag $TAG already exists in this repository"; fi
if command -v gh >/dev/null; then
    if out="$(gh api "repos/$REPO/git/ref/tags/$TAG" 2>&1)"; then
        die "the tag $TAG already exists on github.com/$REPO"
    elif ! grep -q "HTTP 404" <<<"$out"; then
        cannot_check "could not check the tag $TAG on github.com/$REPO: $out"
    fi
    if out="$(gh release view "$TAG" --repo "$REPO" 2>&1)"; then
        die "the release $TAG already exists on github.com/$REPO"
    elif ! grep -qiE "release not found|could not resolve to a repository" <<<"$out"; then
        cannot_check "could not check the release $TAG on github.com/$REPO: $out"
    fi
else
    cannot_check "gh (GitHub CLI) not found: cannot check the tag and release $TAG"
fi

# Write the versions. A dry run puts the Info.plist back as it was when it ends.
if [ "$BUILD" != "$CURRENT_BUILD" ] || [ "$VERSION" != "$CURRENT_VERSION" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        BACKUP="$(mktemp)"
        cp "$PLIST" "$BACKUP"
        trap 'cp "$BACKUP" "$PLIST"; rm -f "$BACKUP"; echo "dry run: $PLIST restored" >&2' EXIT
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
fi
echo "release $VERSION (build $BUILD) of $NAME"

# 2. Build and sign (build-app.sh --release refuses the placeholder key).
if [ "$DRY_RUN" = 1 ]; then bash scripts/build-app.sh; else bash scripts/build-app.sh --release; fi
APP="build/$NAME.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] \
    || die "the built app does not carry build $BUILD"

# 3. Zip (ditto keeps the framework symlinks and the signatures kept in extended attributes),
# then check that what users will unpack still verifies.
OUT=build/release
mkdir -p "$OUT"
ZIP="$OUT/$NAME-$VERSION.zip"
APPCAST="$OUT/appcast.xml"
rm -f "$ZIP" "$APPCAST"
ditto -c -k --keepParent "$APP" "$ZIP"
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/$NAME.app" || { rm -rf "$CHECK"; die "the app unpacked from $ZIP does not verify"; }
rm -rf "$CHECK"

# 4. EdDSA signature: sign_update prints 'sparkle:edSignature="…" length="…"'.
if [ "$DRY_RUN" = 1 ]; then
    ENCLOSURE_SIGNATURE="length=\"$(stat -f%z "$ZIP")\""
else
    ENCLOSURE_SIGNATURE="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP")"
    [[ "$ENCLOSURE_SIGNATURE" == *'sparkle:edSignature="'* ]] || die "sign_update gave no signature: $ENCLOSURE_SIGNATURE"
    # Self-check: the signature verifies against the Keychain key (= SUPublicEDKey, checked above).
    SIGNATURE="$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' <<<"$ENCLOSURE_SIGNATURE")"
    "$SIGN_UPDATE" --verify --account "$SPARKLE_ACCOUNT" "$ZIP" "$SIGNATURE" >/dev/null \
        || die "the EdDSA signature of $ZIP does not verify"
fi

# 5. Appcast: one item, the latest release (the feed URL always serves the latest appcast).
URL="https://github.com/$REPO/releases/download/v$VERSION/$NAME-$VERSION.zip"
NOTES_FILE="docs/release-notes/$VERSION.md"
if [ -f "$NOTES_FILE" ]; then
    NOTES="$(cat "$NOTES_FILE")"
    [[ "$NOTES" != *']]>'* ]] || die "$NOTES_FILE must not contain ']]>'"
    DESCRIPTION="<description sparkle:format=\"markdown\"><![CDATA[$NOTES]]></description>"
else
    DESCRIPTION="<description sparkle:format=\"plain-text\"><![CDATA[$NAME $VERSION]]></description>"
fi
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat >"$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>$NAME</title>
        <link>https://github.com/$REPO</link>
        <description>Updates of $NAME.</description>
        <language>en</language>
        <item>
            <title>$NAME $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
            $DESCRIPTION
            <enclosure url="$URL" $ENCLOSURE_SIGNATURE type="application/octet-stream"/>
        </item>
    </channel>
</rss>
XML
xmllint --noout "$APPCAST" || die "$APPCAST is not well-formed XML"
xpath() { xmllint --xpath "string($1)" "$APPCAST"; }
[ "$(xpath "//*[local-name()='minimumSystemVersion']")" = "$MIN_SYSTEM" ] || die "appcast: minimumSystemVersion"
[ "$(xpath "//*[local-name()='version']")" = "$BUILD" ] || die "appcast: sparkle:version"
[ "$(xpath "//enclosure/@url")" = "$URL" ] || die "appcast: enclosure url"
echo "OK: $ZIP"
echo "OK: $APPCAST (build $BUILD, macOS $MIN_SYSTEM+)"

if [ "$DRY_RUN" = 1 ]; then
    warn_unsigned
    exit 0
fi

# 6. Publish (only with --publish).
if [ "$PUBLISH" = 1 ]; then
    if [ -f "$NOTES_FILE" ]; then NOTES_ARGS=(--notes-file "$NOTES_FILE"); else NOTES_ARGS=(--notes "$NAME $VERSION"); fi
    gh release create "v$VERSION" "$ZIP" "$APPCAST" --repo "$REPO" --title "$NAME $VERSION" \
        --target "$(git rev-parse HEAD)" "${NOTES_ARGS[@]}"
    echo "published: https://github.com/$REPO/releases/tag/v$VERSION"
else
    echo "not published (add --publish to create the GitHub release v$VERSION with both files)"
fi
