#if EMFY_DMG
import Foundation

/// Builds the detached swap-on-quit helper script (U1). Pure and unit-tested: the
/// tests build the script string and assert its quoting and backup/restore logic;
/// the helper is NEVER run against a real app path in tests.
///
/// The helper waits for the running Emfy (by PID) to exit, backs the current bundle
/// up alongside itself (an atomic same-directory `mv`), copies the verified staged
/// app into place with `ditto`, removes the backup on success or restores it on
/// failure, and relaunches with `open`. Every path is single-quote shell-escaped, so
/// a path containing spaces, quotes or `$` can neither break the script nor inject a
/// command.
enum UpdateSwapScript {
    /// Single-quote-escapes a string for POSIX sh: wrap in `'…'`, and render any
    /// embedded single quote as `'\''`.
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The parameters the helper needs. `backupPath` must sit in the same directory
    /// as `targetApp` so the backup `mv` stays on one volume and is atomic.
    struct Parameters {
        let pid: Int32
        let stagedApp: String
        let targetApp: String
        let backupPath: String
        /// Max seconds to wait for the app to quit before giving up without swapping.
        var waitTimeoutSeconds: Int = 120
    }

    /// The full `/bin/sh` script text.
    static func script(_ p: Parameters) -> String {
        let staged = shQuote(p.stagedApp)
        let target = shQuote(p.targetApp)
        let backup = shQuote(p.backupPath)
        let maxIterations = p.waitTimeoutSeconds * 5   // 0.2s per iteration
        return """
        #!/bin/sh
        # Emfy update swap helper (generated). Waits for pid \(p.pid) to exit, then
        # replaces the app bundle in place with a backup, and relaunches.
        set -u
        # Delete this script on every exit path, so it never lingers on disk.
        trap '/bin/rm -f "$0"' EXIT
        i=0
        while kill -0 \(p.pid) 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge \(maxIterations) ]; then
                # The app never quit; do not touch a running bundle.
                exit 1
            fi
            sleep 0.2
        done
        /bin/rm -rf \(backup)
        if /bin/mv \(target) \(backup); then
            if /usr/bin/ditto \(staged) \(target); then
                /bin/rm -rf \(backup)
                /bin/rm -rf \(staged)
            else
                # Restore the backup if the copy failed.
                /bin/rm -rf \(target)
                /bin/mv \(backup) \(target)
                /usr/bin/open \(target)
                exit 1
            fi
        else
            # Could not back up; leave everything untouched and relaunch.
            /usr/bin/open \(target)
            exit 1
        fi
        /usr/bin/open \(target)
        """
    }
}
#endif
