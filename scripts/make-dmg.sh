#!/usr/bin/env bash
#
# make-dmg.sh — assemble a styled Emfy distribution DMG: a custom Finder window
# with the committed background art and a saved icon layout (the app on the
# left, an /Applications drop target on the right), plus a custom volume icon.
#
# Usage:
#   scripts/make-dmg.sh <path-to-Emfy.app> <output-dmg-path>
#
# Uses only system tools: hdiutil, osascript, tiffutil, ditto, xattr, sips,
# and SetFile when present. No third-party tooling.
#
# All staging happens in a mktemp dir OUTSIDE the repo — the repo lives in a
# cloud-synced folder that stamps com.apple.FinderInfo / fileprovider xattrs
# onto files, and those break the app signature during packaging (the same
# reason release.sh works in a scratch dir).
#
# Finder styling requires Automation permission for the calling process. If it
# is missing, this script dies with the exact remedy rather than shipping an
# unstyled DMG.

set -euo pipefail

# --- Arguments ---------------------------------------------------------------

APP="${1:-}"
OUTPUT="${2:-}"

usage() {
    echo "usage: scripts/make-dmg.sh <path-to-Emfy.app> <output-dmg-path>" >&2
}

VOLUME_NAME="Emfy"
MOUNT="/Volumes/${VOLUME_NAME}"
APP_BASENAME="Emfy.app"

info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m    error: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "${APP}" && -n "${OUTPUT}" ]] || { usage; exit 2; }
[[ -d "${APP}" ]] || die "app not found: ${APP}"

# Absolute output path (parent must exist); resolve while its dir is known.
OUTPUT_DIR="$(cd "$(dirname "${OUTPUT}")" && pwd)" || die "output directory does not exist: $(dirname "${OUTPUT}")"
OUTPUT="${OUTPUT_DIR}/$(basename "${OUTPUT}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BG1="${REPO_ROOT}/assets/dmg/background.png"
BG2="${REPO_ROOT}/assets/dmg/background@2x.png"

# --- Pre-flight: refuse to start against a stale mount (task step c) ----------

if [[ -e "${MOUNT}" ]]; then
    die "${MOUNT} already exists — a stale Emfy volume is mounted. Eject it (hdiutil detach \"${MOUNT}\") and re-run."
fi

# --- (a) Background: combine the two PNGs into one hidpi TIFF -----------------

[[ -f "${BG1}" ]] || die "missing background art: ${BG1} (run: swift scripts/make-dmg-background.swift assets/dmg)"
[[ -f "${BG2}" ]] || die "missing background art: ${BG2} (run: swift scripts/make-dmg-background.swift assets/dmg)"

# --- Scratch staging dir OUTSIDE the repo + cleanup trap ---------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emfy-dmg.XXXXXX")"
STAGE="${WORK}/stage"
DEVICE=""

cleanup() {
    # Detach the read-write volume if it is still attached (any failure path),
    # retrying once with -force. Then remove the scratch dir.
    if [[ -n "${DEVICE}" ]]; then
        hdiutil detach "${DEVICE}" >/dev/null 2>&1 \
            || hdiutil detach "${DEVICE}" -force >/dev/null 2>&1 \
            || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

info "combining background art into a hidpi TIFF"
tiffutil -cathidpicheck "${BG1}" "${BG2}" -out "${WORK}/background.tiff" >/dev/null \
    || die "tiffutil failed to build the hidpi background"

# --- (b) Stage the volume contents ------------------------------------------

mkdir -p "${STAGE}/.background"
info "staging app (ditto + xattr strip)"
ditto "${APP}" "${STAGE}/${APP_BASENAME}"
xattr -cr "${STAGE}/${APP_BASENAME}"
ln -s /Applications "${STAGE}/Applications"
cp "${WORK}/background.tiff" "${STAGE}/.background/background.tiff"

# The volume icon (.VolumeIcon.icns + the custom-icon bit) is established LATER,
# after the Finder styling — see step (g). Finder rewrites the volume root's
# Finder info when it saves the window layout, which clears a custom-icon bit set
# beforehand and removes a .VolumeIcon.icns staged into the image (verified
# empirically on this macOS), so setting it up front is futile.
APP_ICNS="${APP}/Contents/Resources/emfy.icns"
[[ -f "${APP_ICNS}" ]] || die "volume icon source not found: ${APP_ICNS}"

# --- (c cont.) Size the image: staged bytes + 20 MB slack for .DS_Store -------

STAGE_KB="$(du -sk "${STAGE}" | awk '{print $1}')"
SIZE_KB=$(( STAGE_KB + 20480 ))
info "staged ${STAGE_KB} KB; creating a ${SIZE_KB} KB read-write image"

# --- (d) Create the read-write image and attach it ---------------------------

hdiutil create \
    -volname "${VOLUME_NAME}" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -srcfolder "${STAGE}" \
    "${WORK}/rw.dmg" >/dev/null \
    || die "hdiutil create failed"

info "attaching read-write volume"
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "${WORK}/rw.dmg")" \
    || die "hdiutil attach failed"
DEVICE="$(echo "${ATTACH_OUT}" | grep -Eo '^/dev/disk[0-9]+' | head -1)"
[[ -n "${DEVICE}" ]] || die "could not determine attached device node"
[[ -d "${MOUNT}" ]] || die "volume did not mount at ${MOUNT}"

# --- (e) Style the Finder window --------------------------------------------

# Small osascript-based pause so we never call the sandbox-blocked shell `sleep`
# and Finder gets time to flush its .DS_Store.
pause() { osascript -e "delay ${1}" >/dev/null 2>&1 || true; }

# Detect the "Automation not authorized" failure specifically and give the
# operator the exact remedy — never fall through to an unstyled DMG.
osa_authz_die() {
    die "Finder automation is not authorized for the calling app.
    Grant it in System Settings › Privacy & Security › Automation:
    enable the Finder checkbox for the terminal/app running this script, then re-run.
    (osascript reported: ${1})"
}

STYLE_SCRIPT=$(cat <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Emfy"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        -- Bounds EXCLUDE the 32pt title bar, so content height = 602 - 120 - 32
        -- = 450pt, equal to the art height, mapping the 700x450 art 1:1 from the
        -- top-left. Finder anchors the background top-left at natural size and
        -- clips it; it does not scale. The blank bottom margin of the art absorbs
        -- a ~28pt path/status bar when the user has one enabled, so only paper is
        -- hidden below the tagline. 602 was measured correct on the target Mac.
        set the bounds of container window to {200, 120, 900, 602}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 12
        set background picture of theViewOptions to POSIX file "/Volumes/Emfy/.background/background.tiff"
        delay 1
        set position of item "Emfy.app" of container window to {200, 215}
        set position of item "Applications" of container window to {500, 215}
        update without registering applications
        delay 1
        close
        delay 1
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
)

info "styling the Finder window"
if ! STYLE_OUT="$(osascript -e "${STYLE_SCRIPT}" 2>&1)"; then
    if echo "${STYLE_OUT}" | grep -qiE '(-1743|not authorized|not allowed|assistive access)'; then
        osa_authz_die "${STYLE_OUT}"
    fi
    die "Finder styling failed: ${STYLE_OUT}"
fi

sync

# --- (f) VERIFY the styling actually took, before unmounting -----------------

VERIFY_SCRIPT=$(cat <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Emfy"
        set b to the bounds of container window
        set vo to the icon view options of container window
        set isz to icon size of vo
        try
            set bg to (background picture of vo) as text
        on error
            set bg to "(none)"
        end try
        return "" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & "|" & isz & "|" & bg
    end tell
end tell
APPLESCRIPT
)

if ! VERIFY_OUT="$(osascript -e "${VERIFY_SCRIPT}" 2>&1)"; then
    if echo "${VERIFY_OUT}" | grep -qiE '(-1743|not authorized|not allowed|assistive access)'; then
        osa_authz_die "${VERIFY_OUT}"
    fi
    die "Finder verification query failed: ${VERIFY_OUT}"
fi

GOT_BOUNDS="${VERIFY_OUT%%|*}"
REST="${VERIFY_OUT#*|}"
GOT_ICON="${REST%%|*}"
GOT_BG="${REST#*|}"

info "Finder reports: bounds={${GOT_BOUNDS}} iconSize=${GOT_ICON} background=${GOT_BG}"

[[ "${GOT_BOUNDS}" == "200,120,900,602" ]] \
    || die "window bounds did not stick (got {${GOT_BOUNDS}}, expected {200,120,900,602})"
[[ "${GOT_ICON}" == "128" ]] \
    || die "icon size did not stick (got ${GOT_ICON}, expected 128)"

# .DS_Store must exist and be substantial (a tiny/absent one means the layout
# was not flushed). Give Finder a couple of extra nudges if it is lagging.
DS="${MOUNT}/.DS_Store"
ds_size() { [[ -f "${DS}" ]] && stat -f%z "${DS}" || echo 0; }
for _ in 1 2 3 4 5; do
    [[ "$(ds_size)" -gt 4096 ]] && break
    osascript -e 'tell application "Finder" to update disk "Emfy" without registering applications' >/dev/null 2>&1 || true
    pause 0.6
    sync
done
DS_SIZE="$(ds_size)"
[[ "${DS_SIZE}" -gt 4096 ]] \
    || die "${DS} is missing or too small (${DS_SIZE} bytes) — the Finder layout did not persist"
info "verified .DS_Store present (${DS_SIZE} bytes)"

# Background picture. Finder's `background picture` property THROWS on read on
# current macOS (its handler fails), so GOT_BG can read "(none)" even when the
# picture is correctly set. Accept a positive Finder read when the OS allows it;
# otherwise confirm the ground truth — the background image reference Finder
# recorded inside .DS_Store's icon-view (icvp) plist, where the image filename
# is embedded in the stored bookmark.
if echo "${GOT_BG}" | grep -q "background.tiff"; then
    info "verified background picture via Finder (${GOT_BG})"
elif LC_ALL=C grep -aq "background.tiff" "${DS}"; then
    info "verified background picture via .DS_Store reference (Finder read unavailable on this macOS)"
else
    die "background picture did not stick — no reference to background.tiff in the Finder window or in ${DS}"
fi

# --- (g) Establish the custom volume icon (AFTER Finder is done) --------------

# Finder rewrites the volume root's Finder info when it saves the window layout,
# which CLEARS the custom-icon bit and REMOVES a pre-staged .VolumeIcon.icns
# (verified empirically). So the icon must be set LAST: close the Finder window,
# then drop in .VolumeIcon.icns and set the bit while nothing is managing the
# volume. This survives the UDZO convert.
CLOSE_SCRIPT='tell application "Finder"
    try
        close container window of disk "Emfy"
    end try
end tell'
osascript -e "${CLOSE_SCRIPT}" >/dev/null 2>&1 || true
pause 1
sync

info "placing .VolumeIcon.icns"
cp "${APP_ICNS}" "${MOUNT}/.VolumeIcon.icns" || die "could not copy .VolumeIcon.icns onto the volume"

SETFILE="$(xcrun --find SetFile 2>/dev/null || true)"
if [[ -z "${SETFILE}" && -x "/Applications/Xcode.app/Contents/Developer/usr/bin/SetFile" ]]; then
    SETFILE="/Applications/Xcode.app/Contents/Developer/usr/bin/SetFile"
fi
GETFILEINFO="$(xcrun --find GetFileInfo 2>/dev/null || true)"
if [[ -z "${GETFILEINFO}" && -x "/Applications/Xcode.app/Contents/Developer/usr/bin/GetFileInfo" ]]; then
    GETFILEINFO="/Applications/Xcode.app/Contents/Developer/usr/bin/GetFileInfo"
fi

if [[ -n "${SETFILE}" && -x "${SETFILE}" ]]; then
    info "setting custom-icon bit via SetFile"
    "${SETFILE}" -a C "${MOUNT}" || die "SetFile could not set the custom-icon attribute"
    # Confirm the catalog flag actually took — Finder is known to clear it, and a
    # cleared bit yields a generic volume icon with no other symptom. The
    # attributes line reads e.g. "avbstClinmedz"; uppercase C == custom icon set.
    if [[ -n "${GETFILEINFO}" && -x "${GETFILEINFO}" ]]; then
        if "${GETFILEINFO}" "${MOUNT}" 2>/dev/null | grep -E '^attributes:' | grep -q 'C'; then
            info "verified custom-icon bit is set"
        else
            die "custom-icon bit did not stick on ${MOUNT} (GetFileInfo reports it clear)"
        fi
    else
        warn "GetFileInfo unavailable — custom-icon bit set but not positively confirmed"
    fi
else
    # FinderInfo bytes 8–9 are the Finder flags; 0x0400 is kHasCustomIcon.
    info "setting custom-icon bit via xattr FinderInfo (SetFile unavailable)"
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" \
        "${MOUNT}" || die "could not write com.apple.FinderInfo custom-icon flag"
    warn "SetFile unavailable — custom-icon FinderInfo written but not positively confirmed"
fi

[[ -f "${MOUNT}/.VolumeIcon.icns" ]] \
    || die ".VolumeIcon.icns missing from ${MOUNT} after establishing the volume icon"
info "verified .VolumeIcon.icns present on the volume"
sync

# --- (h) Flush, detach, and compress -----------------------------------------

sync
info "detaching read-write volume"
hdiutil detach "${DEVICE}" >/dev/null \
    || hdiutil detach "${DEVICE}" -force >/dev/null \
    || die "could not detach ${DEVICE}"
DEVICE=""   # detached cleanly — stop the EXIT trap from re-detaching

info "compressing to UDZO: ${OUTPUT}"
rm -f "${OUTPUT}"
hdiutil convert "${WORK}/rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${OUTPUT}" >/dev/null \
    || die "hdiutil convert failed"

info "styled DMG written: ${OUTPUT}"
