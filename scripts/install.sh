#!/bin/bash
# Install a verified build at the fixed path used by Accessibility and login items.
# Existing versions are kept as a temporary backup rather than deleted in place.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: bash scripts/install.sh /private/tmp/MouseYBoost-build.XXXXXX/MouseYBoost.app" >&2
    exit 1
fi
source_app="$1"
destination="/Applications/MouseYBoost.app"
identity="659A2CD838DF7ADCB88F313BDE6572A223C4923C"
requirement="=identifier \"com.local.MouseYBoost\" and certificate root = H\"$identity\""
codesign --verify --deep --strict -R "$requirement" "$source_app"

# Same-volume staging makes the final move atomic while preserving a rollback copy.
staging="$(mktemp -d /Applications/.MouseYBoost-install.XXXXXX)"
trap 'rmdir "$staging" 2>/dev/null || true' EXIT
ditto "$source_app" "$staging/MouseYBoost.app"
codesign --verify --deep --strict -R "$requirement" "$staging/MouseYBoost.app"
if [[ -e "$destination" ]]; then
    echo "Quit MouseYBoost before replacing the installed application." >&2
    if pgrep -x MouseYBoost >/dev/null; then
        exit 1
    fi
    backup_dir="$(mktemp -d /private/tmp/MouseYBoost-backup.XXXXXX)"
    mv "$destination" "$backup_dir/MouseYBoost.app"
    echo "Previous version saved: $backup_dir/MouseYBoost.app"
fi
if ! mv "$staging/MouseYBoost.app" "$destination"; then
    if [[ -n "${backup_dir:-}" && ! -e "$destination" ]]; then
        mv "$backup_dir/MouseYBoost.app" "$destination"
    fi
    exit 1
fi
codesign --verify --deep --strict -R "$requirement" "$destination"
open "$destination" --args --settings
echo "Installed: $destination"
