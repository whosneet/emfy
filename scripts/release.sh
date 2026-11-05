#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package Emfy for Developer ID
# distribution (a notarized DMG on GitHub releases).
#
# The Release configuration already carries the signing settings (Manual code
# signing with "Developer ID Application", team 6Y294JNMJ2, hardened runtime on
# the app and both Quick Look appexes). The Developer ID identity used to sign
# the DMG is discovered at runtime from the keychain by team id, so the
# certificate's common name is never hardcoded (it changes when the Apple
# Developer account type changes, e.g. individual -> company). This script
# drives the clean build, the signature/Gatekeeper checks, notarization,
# stapling, and DMG packaging around that, and prints a final verification
# block with artifact paths and hashes.
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
# The Emfy scheme is multiplatform (macOS + iOS). Pin the Mac so xcodebuild
# never resolves an iOS destination for this Developer ID / DMG build.
DESTINATION="generic/platform=macOS"

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

# Developer ID identity used to sign the DMG (explicitly, below); the app
# itself is signed by xcodebuild via the project's Developer ID settings. The
# certificate is discovered at runtime from the keychain by TEAM_ID (see
# resolve_signing_identity) rather than by a hardcoded common name, which
# changes when the account type changes. DEVELOPER_ID_HASH is the SHA-1 the DMG
# is signed with; DEVELOPER_ID_APP is its human-readable name, for messages.
TEAM_ID="6Y294JNMJ2"
DEVELOPER_ID_HASH=""
DEVELOPER_ID_APP=""

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

# Submit an artifact to the notary service and REQUIRE an Accepted verdict.
# `notarytool submit --wait` exits 0 even when the verdict is Invalid, so its
# exit status cannot be trusted — the output must be parsed. This captures the
# submission log (shown live via tee) and only returns success on a final
# "status: Accepted"; otherwise it dies, printing the submission id and the
# exact command to fetch the detailed failure log.
#   $1 — path to the artifact (zip or dmg)
#   $2 — human label for messages ("app", "DMG")
notarize_and_verify() {
    local artifact="$1" label="$2"
    local out
    out="$(mktemp "${WORK_DIR}/notary-${label}.XXXXXX")"

    # Tee so the operator sees progress live; keep the text for parsing. The
    # `|| true` stops set -e from aborting before we can inspect the verdict.
    xcrun notarytool submit "${artifact}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait 2>&1 | tee "${out}" || true

    # First "  id:" line is the submission id (value after the colon).
    local submission_id
    submission_id="$(awk -F': *' '/^ *id:/{print $2; exit}' "${out}")"

    # Verdict: the final-block "  status:" line (anchored to exclude the
    # "Current status:" polling lines); take the last such line.
    local status
    status="$(awk -F': *' '/^ *status:/{v=$2} END{print v}' "${out}")"

    if [[ "${status}" != "Accepted" ]]; then
        die "notarization of the ${label} was not Accepted (status: ${status:-unknown}).
    submission id: ${submission_id:-unknown}
    fetch the detailed log with:
      xcrun notarytool log ${submission_id:-<submission-id>} --keychain-profile ${NOTARY_PROFILE}"
    fi
    info "notarization Accepted (submission id: ${submission_id:-unknown})"
}

# Resolve the Developer ID Application signing identity for TEAM_ID from the
# keychain and set DEVELOPER_ID_HASH / DEVELOPER_ID_APP. Matching by team id
# (not a hardcoded common name) keeps the script working across a certificate
# reissue that changes the name — e.g. when the account converts from
# individual to company. The DMG is signed by the SHA-1 hash, so the pick stays
# unambiguous even if an old and a renewed certificate for the same team
# coexist during a renewal; when several match, the last one listed is used and
# reported so the operator can confirm it. Dies if none is present.
resolve_signing_identity() {
    # find-identity lines read: '  N) <40-hex SHA-1> "<name>"'. Keep only
    # "Developer ID Application: … (TEAM_ID)" rows; emit "<sha1>\t<name>".
    local matches
    matches="$(security find-identity -v -p codesigning | awk -v team="(${TEAM_ID})" '
        /Developer ID Application:/ && index($0, team) {
            q1 = index($0, "\"")
            name = substr($0, q1 + 1); sub(/"$/, "", name)
            print $2 "\t" name
        }')"
    [[ -n "${matches}" ]] || die "no \"Developer ID Application: … (${TEAM_ID})\" identity found in the keychain.
    list identities with: security find-identity -v -p codesigning
    import the Developer ID Application certificate for team ${TEAM_ID} and retry."

    local n chosen
    n="$(printf '%s\n' "${matches}" | grep -c .)"
    chosen="$(printf '%s\n' "${matches}" | tail -1)"
    DEVELOPER_ID_HASH="${chosen%%$'\t'*}"
    DEVELOPER_ID_APP="${chosen#*$'\t'}"

    if [[ "${n}" -gt 1 ]]; then
        warn "${n} Developer ID Application certificates match team ${TEAM_ID} (renewal overlap?); using the last listed"
    fi
    info "signing identity: ${DEVELOPER_ID_APP} [${DEVELOPER_ID_HASH}]"
}

if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    printf '\033[1mEmfy release — DRY RUN (--skip-notarize): notarization and stapling are skipped\033[0m\n'
else
    printf '\033[1mEmfy release — FULL RUN: notary profile "%s"\033[0m\n' "${NOTARY_PROFILE}"
fi

# --- Resolve the Developer ID signing identity -------------------------------

step "Resolve the Developer ID signing identity (team ${TEAM_ID})"
resolve_signing_identity

# --- 1. Clean Release build --------------------------------------------------

step "Clean Release build (scheme ${SCHEME}, configuration ${CONFIGURATION})"
mkdir -p "${DIST_DIR}"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    clean build

# Resolve the built app path from the build settings (first target = app).
PRODUCTS_DIR="$(
    xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" \
        -destination "${DESTINATION}" \
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
    notarize_and_verify "${APP_ZIP}" "app"
    info "stapling notarization ticket to the app"
    xcrun stapler staple "${STAGED_APP}" \
        || die "stapler staple failed for the app"
    info "app stapled"
    info "re-zipping the stapled app for dist"
    rm -f "${APP_ZIP}"
    ditto -c -k --keepParent "${STAGED_APP}" "${APP_ZIP}"
fi

# --- 4. Build, sign, notarize, and staple the DMG ----------------------------

step "Build the styled DMG (UDZO, volume \"${VOLUME_NAME}\", custom Finder window)"
DMG_PATH="${WORK_DIR}/${DMG_NAME}"
rm -f "${DMG_PATH}"

# Styled drag-to-install layout — custom Finder window (background art + saved
# icon positions) plus a custom volume icon — is assembled by make-dmg.sh from
# the staged, signed app.
info "assembling styled DMG via scripts/make-dmg.sh"
"${REPO_ROOT}/scripts/make-dmg.sh" "${STAGED_APP}" "${DMG_PATH}"

step "Sign the DMG with Developer ID (${DEVELOPER_ID_APP})"
codesign --force --timestamp --sign "${DEVELOPER_ID_HASH}" "${DMG_PATH}" \
    || die "codesign of the DMG failed"
codesign --verify --verbose=2 "${DMG_PATH}" \
    || die "codesign --verify failed on the DMG"
info "DMG signed and verified"

step "Notarize and staple the DMG"
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    warn "skipping notarytool submit + stapler staple for the DMG (dry run)"
else
    info "submitting DMG to notary service (profile: ${NOTARY_PROFILE})"
    notarize_and_verify "${DMG_PATH}" "DMG"
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
