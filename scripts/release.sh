#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package Emfy for Developer ID
# distribution (a notarized DMG on GitHub releases).
#
# The Release configuration already carries the signing settings (Manual code
# signing with "Developer ID Application", team 6Y294JNMJ2, hardened runtime on
# the app and both Quick Look appexes). This script drives the clean build, the
# signature/Gatekeeper checks, notarization, stapling, and DMG packaging around
# that, and prints a final verification block with artifact paths and hashes.
#
# Usage:
#   scripts/release.sh [--skip-notarize] [--profile <keychain-profile>]
#
#   --skip-notarize   Dry run: build, sign, package, and verify everything that
#                     does NOT need notarization credentials. Every notarytool
#                     and stapler step is skipped; the pre-notarization spctl
#                     rejection is reported but is NOT fatal. This is the mode
#                     that runs end to end before notary credentials exist.
#   --profile <name>  notarytool keychain profile to use (default: emfy-notary).
#                     Create it once with:
#                       xcrun notarytool store-credentials emfy-notary \
#                         --apple-id <id> --team-id 6Y294JNMJ2 --password <app-specific>
#
# Outputs land under dist/ (gitignored).

set -euo pipefail

# --- Configuration -----------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/Emfy/Emfy.xcodeproj"
SCHEME="Emfy"
CONFIGURATION="Release"

DIST_DIR="${REPO_ROOT}/dist"

# Build products and DMG assembly happen in a scratch directory OUTSIDE the
# repo. The repo lives in a file-provider-managed (iCloud/cloud-synced) folder
# that stamps com.apple.FinderInfo / fileprovider xattrs onto every file it
# holds, and codesign under the hardened runtime rejects those as "resource
# fork, Finder information, or similar detritus". Only the final artifacts are
# copied back into dist/. DerivedData is a build cache, not a release output.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emfy-release.XXXXXX")"
DERIVED_DATA="${WORK_DIR}/DerivedData"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# Developer ID identity used to sign the app (via the project settings) and the
# DMG (explicitly, below). Must be present in the keychain.
DEVELOPER_ID_APP="Developer ID Application: Avneet Singh (6Y294JNMJ2)"

APP_NAME="Emfy.app"
VOLUME_NAME="Emfy"
DMG_NAME="Emfy.dmg"

# --- Arguments ---------------------------------------------------------------

SKIP_NOTARIZE=0
NOTARY_PROFILE="emfy-notary"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize)
            SKIP_NOTARIZE=1
            shift
            ;;
        --profile)
            NOTARY_PROFILE="${2:?--profile needs a keychain-profile name}"
            shift 2
            ;;
        -h|--help)
            # Print the header comment block (skip the shebang line).
            sed -n '2,/^set -euo/{/^set -euo/d; s/^#\{1,2\} \{0,1\}//; s/^#$//; p;}' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "usage: scripts/release.sh [--skip-notarize] [--profile <keychain-profile>]" >&2
            exit 2
            ;;
    esac
done

# --- Logging helpers ---------------------------------------------------------

STEP=0
step() {
    STEP=$((STEP + 1))
    printf '\n\033[1m==> [%d] %s\033[0m\n' "$STEP" "$*"
}
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()   { printf '\033[31m    error: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    printf '\033[1mEmfy release — DRY RUN (--skip-notarize): notarization and stapling are skipped\033[0m\n'
else
    printf '\033[1mEmfy release — FULL RUN: notary profile "%s"\033[0m\n' "${NOTARY_PROFILE}"
fi

# --- 1. Clean Release build --------------------------------------------------

step "Clean Release build (scheme ${SCHEME}, configuration ${CONFIGURATION})"
mkdir -p "${DIST_DIR}"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    clean build

# Resolve the built app path from the build settings (first target = app).
PRODUCTS_DIR="$(
    xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" \
        -derivedDataPath "${DERIVED_DATA}" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ TARGET_BUILD_DIR = /{print $2; exit}'
)"
[[ -n "${PRODUCTS_DIR}" ]] || die "could not resolve TARGET_BUILD_DIR from build settings"

APP_PATH="${PRODUCTS_DIR}/${APP_NAME}"
[[ -d "${APP_PATH}" ]] || die "built app not found at ${APP_PATH}"
info "built: ${APP_PATH}"

# Stage a clean copy of the app in the scratch work dir so packaging never
# touches the build products directory, then strip any lingering extended
# attributes so the signature stays intact through zipping and DMG assembly.
STAGE_DIR="${WORK_DIR}/stage"
mkdir -p "${STAGE_DIR}"
ditto "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}"
STAGED_APP="${STAGE_DIR}/${APP_NAME}"
xattr -cr "${STAGED_APP}"
info "staged: ${STAGED_APP}"

# --- 2. Verify signatures ----------------------------------------------------

step "Verify code signatures"
info "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}" \
    || die "codesign --verify --deep --strict failed on ${APP_NAME}"
info "signature valid and satisfies its Designated Requirement"

# Gatekeeper assessment. Before notarization this MUST fail with
# "source=Unnotarized Developer ID" — that is expected, not an error. In a full
# run the meaningful spctl assessment happens AFTER stapling (step 5); here we
# only surface the current state.
info "spctl --assess --type execute (pre-notarization state)"
if spctl --assess --type execute --verbose=4 "${STAGED_APP}" 2>&1; then
    info "spctl: accepted"
else
    if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
        warn "spctl rejected the app — expected before notarization; continuing (dry run)"
    else
        info "spctl rejected the app — expected before notarization; will re-check after stapling"
    fi
fi

# --- 3. Notarize and staple the app ------------------------------------------

step "Notarize and staple the app"
APP_ZIP="${WORK_DIR}/${APP_NAME}.zip"
info "zipping app for submission: ${APP_ZIP}"
ditto -c -k --keepParent "${STAGED_APP}" "${APP_ZIP}"

if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    warn "skipping notarytool submit + stapler staple for the app (dry run)"
else
    info "submitting to notary service (profile: ${NOTARY_PROFILE}); this waits for the result"
    xcrun notarytool submit "${APP_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        || die "notarytool submit failed for the app"
    info "stapling notarization ticket to the app"
    xcrun stapler staple "${STAGED_APP}" \
        || die "stapler staple failed for the app"
    info "app stapled"
fi

# --- 4. Build, sign, notarize, and staple the DMG ----------------------------

step "Build the DMG (UDZO, volume \"${VOLUME_NAME}\", app + /Applications)"
DMG_PATH="${WORK_DIR}/${DMG_NAME}"
DMG_STAGE="${WORK_DIR}/dmg-stage"
rm -rf "${DMG_STAGE}" "${DMG_PATH}"
mkdir -p "${DMG_STAGE}"

# Standard drag-to-install layout: the app plus a symlink to /Applications.
ditto "${STAGED_APP}" "${DMG_STAGE}/${APP_NAME}"
xattr -cr "${DMG_STAGE}/${APP_NAME}"
ln -s /Applications "${DMG_STAGE}/Applications"

info "creating compressed DMG: ${DMG_PATH}"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

step "Sign the DMG with Developer ID"
codesign --force --timestamp --sign "${DEVELOPER_ID_APP}" "${DMG_PATH}" \
    || die "codesign of the DMG failed"
codesign --verify --verbose=2 "${DMG_PATH}" \
    || die "codesign --verify failed on the DMG"
info "DMG signed and verified"

step "Notarize and staple the DMG"
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    warn "skipping notarytool submit + stapler staple for the DMG (dry run)"
else
    info "submitting DMG to notary service (profile: ${NOTARY_PROFILE})"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        || die "notarytool submit failed for the DMG"
    info "stapling notarization ticket to the DMG"
    xcrun stapler staple "${DMG_PATH}" \
        || die "stapler staple failed for the DMG"
    info "DMG stapled"
fi

# --- 5. Final verification ---------------------------------------------------

step "Final verification"

if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    warn "stapler validate / notarized spctl checks skipped (dry run — nothing was stapled)"
    warn "artifacts below are correctly SIGNED but NOT notarized; a full run is required to ship"
else
    info "stapler validate — app"
    xcrun stapler validate "${STAGED_APP}" || die "stapler validate failed for the app"
    info "stapler validate — DMG"
    xcrun stapler validate "${DMG_PATH}" || die "stapler validate failed for the DMG"

    info "spctl --assess --type execute — app (post-staple, expect: accepted)"
    spctl --assess --type execute --verbose=4 "${STAGED_APP}" \
        || die "spctl rejected the app after stapling — notarization did not take"
    info "spctl --assess --type open — DMG (post-staple, expect: accepted)"
    spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}" \
        || die "spctl rejected the DMG after stapling"
fi

step "Collect artifacts under dist/"
# WORK_DIR is scratch and is removed on exit; copy the shippable artifacts into
# dist/ (the app, its submission zip, and the DMG). These carry the completed
# signatures — and, in a full run, the stapled notarization tickets.
rm -rf "${DIST_DIR:?}/${APP_NAME}" "${DIST_DIR}/${APP_NAME}.zip" "${DIST_DIR}/${DMG_NAME}"
ditto "${STAGED_APP}" "${DIST_DIR}/${APP_NAME}"
cp -c "${APP_ZIP}" "${DIST_DIR}/${APP_NAME}.zip" 2>/dev/null || cp "${APP_ZIP}" "${DIST_DIR}/${APP_NAME}.zip"
cp -c "${DMG_PATH}" "${DIST_DIR}/${DMG_NAME}" 2>/dev/null || cp "${DMG_PATH}" "${DIST_DIR}/${DMG_NAME}"

FINAL_APP="${DIST_DIR}/${APP_NAME}"
FINAL_ZIP="${DIST_DIR}/${APP_NAME}.zip"
FINAL_DMG="${DIST_DIR}/${DMG_NAME}"

info "app: ${FINAL_APP}"
info "zip: ${FINAL_ZIP}"
info "dmg: ${FINAL_DMG}"
echo
echo "SHA-256:"
shasum -a 256 "${FINAL_DMG}" "${FINAL_ZIP}"

echo
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    printf '\033[1mDRY RUN complete: built, signed, and packaged — NOT notarized.\033[0m\n'
else
    printf '\033[1mRelease complete: notarized, stapled, and packaged.\033[0m\n'
fi
