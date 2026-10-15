#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build release, assemble build/<name>.app (name = CFBundleExecutable in
# Resources/Info.plist, also the SwiftPM product) and sign it with a stable
# identity so macOS keeps the Microphone/Accessibility grants across builds
# (ad-hoc signing works too, but the grants are then asked again after each build).
#
#   bash scripts/build-app.sh            development build (any SUPublicEDKey)
#   bash scripts/build-app.sh --release  refuses to build while SUPublicEDKey is the placeholder
#                                        (scripts/release.sh uses it; see docs/RELEASING.md)
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        *) echo "usage: $0 [--release]" >&2; exit 2 ;;
    esac
done
# Must match UpdateConfiguration.publicKeyPlaceholder (TranscricaoCore).
KEY_PLACEHOLDER="REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
if [ "$RELEASE" = 1 ]; then
    KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist 2>/dev/null || true)"
    if [ -z "$KEY" ] || [ "$KEY" = "$KEY_PLACEHOLDER" ]; then
        echo "error: SUPublicEDKey in Resources/Info.plist is empty or the placeholder; a release" >&2
        echo "       build needs the public key from Sparkle's generate_keys (docs/RELEASING.md)." >&2
        exit 1
    fi
    # Same rule as UpdateConfiguration.isValidPublicKey: base64 of exactly 32 bytes. A malformed key
    # ships an app whose updater never starts. `base64 -D` skips whitespace that Data(base64Encoded:)
    # rejects, so only base64 characters are allowed.
    if [[ ! "$KEY" =~ ^[A-Za-z0-9+/]+=*$ ]] \
        || [ "$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then
        echo "error: SUPublicEDKey in Resources/Info.plist is not an EdDSA public key (base64 of 32 bytes)." >&2
        exit 1
    fi
fi

NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Resources/Info.plist)"
APP="build/$NAME.app"
# Signing identity: CODESIGN_IDENTITY from the environment or from the git-ignored
# scripts/local.env (see scripts/local.env.example); ad-hoc ("-") without either.
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -f scripts/local.env ]; then
    # shellcheck disable=SC1091
    source scripts/local.env
fi
IDENTITY="${CODESIGN_IDENTITY:--}"

# --disable-keychain: every dependency is public; without it SwiftPM looks up github.com credentials
# in the Keychain and can hold the build on a Keychain dialog.
# Macro prefix maps: __FILE__ in the C/C++ of the dependencies (error messages in mlx, mlx-c, fmt,
# xgrammar) becomes relative to the repository, so the shipped binary never contains the builder's
# home folder. Only __FILE__ is remapped: remapping the debug info as well (-ffile-prefix-map,
# swiftc -file-prefix-map) breaks dsymutil's lookup of the precompiled modules. The check after
# `strip` below fails the build if any absolute path is left.
ROOT="$PWD"
PREFIX_MAP=(
    -Xcc "-fmacro-prefix-map=$ROOT=."
    -Xcxx "-fmacro-prefix-map=$ROOT=."
)
swift build --disable-keychain -c release "${PREFIX_MAP[@]}" --product "$NAME"
BIN="$(swift build --disable-keychain -c release "${PREFIX_MAP[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The GPL and every third-party license and NOTICE text ship with the binary (Credits window).
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# SwiftPM resource bundles (MLX ships its Metal kernels in mlx-swift_Cmlx.bundle; the app's own
# bundle holds the UI localizations).
for bundle in "$BIN"/*.bundle; do
    if [ -e "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
# The localizations must sit in Contents/Resources itself: Bundle.main (String(localized:), SwiftUI
# Text) and InfoPlist.strings (microphone prompt) are only looked up there, not in the SwiftPM bundle.
APP_BUNDLE="$BIN/Transcricao_Transcricao.bundle" # <package>_<target>
LPROJ_ROOT="$APP_BUNDLE"
[ -d "$APP_BUNDLE/Contents/Resources" ] && LPROJ_ROOT="$APP_BUNDLE/Contents/Resources"
found=0
for lproj in "$LPROJ_ROOT"/*.lproj; do
    if [ -d "$lproj" ]; then cp -R "$lproj" "$APP/Contents/Resources/"; found=1; fi
done
if [ "$found" = 0 ]; then
    echo "error: no .lproj in the app's resource bundle ($APP_BUNDLE)" >&2
    exit 1
fi
# MLX also looks for mlx.metallib next to the executable.
METALLIB="$BIN/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ ! -f "$METALLIB" ]; then
    echo "error: $METALLIB not found (is the Metal Toolchain installed?)" >&2
    exit 1
fi
cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"

# Sparkle (automatic updates, spec §6). ditto keeps the framework's Versions/Current symlinks.
SPARKLE_SRC="$BIN/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "error: $SPARKLE_SRC not found (swift package resolve --disable-keychain?)" >&2
    exit 1
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SRC" "$SPARKLE"
# The app is not sandboxed: Sparkle downloads and installs without its XPC services (they are
# only used with SUEnableDownloaderService / SUEnableInstallerLauncherService), so they go, as
# Sparkle's sandboxing docs allow.
rm -rf "$SPARKLE/Versions/B/XPCServices"
rm -f "$SPARKLE/XPCServices"
# The executable finds @rpath/Sparkle.framework (and the Swift back-deployment libraries below)
# in Contents/Frameworks.
EXE="$APP/Contents/MacOS/$NAME"
if ! otool -l "$EXE" | grep -q "path @executable_path/../Frameworks "; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
fi
# Swift back-deployment libraries (e.g. libswiftCompatibilitySpan.dylib): macOS 26+ has them in
# /usr/lib/swift (searched first); older systems load the copy in Contents/Frameworks. SwiftPM only
# points at the toolchain with absolute rpaths, which exist on this Mac alone: copy each library
# from there, then drop those rpaths (/usr/lib/swift and @loader_path stay).
RPATHS="$(otool -l "$EXE" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')"
for lib in $(otool -L "$EXE" | awk '$1 ~ /^@rpath\/libswift.*\.dylib$/ {sub("@rpath/", "", $1); print $1}'); do
    found=""
    for dir in $RPATHS; do
        case "$dir" in /usr/lib/swift|@*) continue ;; esac
        if [ -f "$dir/$lib" ]; then found="$dir/$lib"; break; fi
    done
    if [ -z "$found" ]; then
        if [ -f "/usr/lib/swift/$lib" ]; then
            echo "warning: $lib only found in /usr/lib/swift (not embedded; needs macOS 26+)" >&2
            continue
        fi
        echo "error: @rpath/$lib not found in the toolchain rpaths" >&2
        exit 1
    fi
    cp "$found" "$APP/Contents/Frameworks/$lib"
done
for dir in $RPATHS; do
    case "$dir" in /usr/lib/swift|@*) ;; *) install_name_tool -delete_rpath "$dir" "$EXE" ;; esac
done
# Debug-map entries (N_OSO: the absolute paths of the object files) are not needed at run time;
# dropping them keeps build paths out of the shipped executable. Local symbols stay (crash reports).
strip -S "$EXE"
# No file of the bundle may contain this checkout's absolute path or the builder's home folder.
if LC_ALL=C grep -rlaF -e "$ROOT/" -e "$HOME/" "$APP" >/dev/null; then
    echo "error: build paths left in the bundle:" >&2
    LC_ALL=C grep -rlaF -e "$ROOT/" -e "$HOME/" "$APP" >&2
    exit 1
fi

# Sign inside-out with one identity, never --deep: Sparkle's helpers (keeping their hardened
# runtime, as Sparkle's docs do), then the framework, then the app (no hardened runtime: the
# microphone would need an entitlement).
sign() { codesign --force --sign "$IDENTITY" "$@"; }
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    if [ -e "$dylib" ]; then sign "$dylib"; fi
done
sign -o runtime "$SPARKLE/Versions/B/Autoupdate"
sign -o runtime "$SPARKLE/Versions/B/Updater.app"
sign -o runtime "$SPARKLE"
# Anything else next to the executable is nested code to codesign (mlx.metallib: the signature
# goes in its extended attributes, which ditto keeps in the release zip).
for extra in "$APP/Contents/MacOS"/*; do
    if [ "$extra" != "$APP/Contents/MacOS/$NAME" ]; then sign "$extra"; fi
done
sign "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
echo "OK: $APP"
