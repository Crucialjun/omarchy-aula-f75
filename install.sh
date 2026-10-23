#!/bin/bash
# Manual install for a checkout that is not (yet) a git remote:
#   ./install.sh            copy into ~/.config/omarchy/plugins and enable
#   ./install.sh --link     symlink the checkout instead (dev mode; note that
#                           `omarchy plugin validate` rejects symlinks *inside*
#                           a plugin, a symlinked plugin folder is fine)
set -euo pipefail

ID="crucialjun.aula-f75"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.config/omarchy/plugins/$ID"

mkdir -p "$(dirname "$DST")"
if [[ ${1:-} == --link ]]; then
  rm -rf "$DST"
  ln -s "$SRC" "$DST"
else
  rm -rf "$DST"
  cp -r "$SRC" "$DST"
  rm -rf "$DST/.git" "$DST"/*/__pycache__
fi
chmod +x "$DST/bin/aula-f75"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins || true
  # The rescan is asynchronous; give the registry a moment before enabling.
  enabled=0
  for _ in 1 2 3 4 5 6; do
    if omarchy plugin enable "$ID" >/dev/null 2>&1; then enabled=1; break; fi
    sleep 1
  done
  if [[ $enabled == 1 ]]; then
    omarchy bar put "$ID" --section right >/dev/null 2>&1 || true
    echo "Enabled $ID. Open the panel from the bar and click 'Grant access' once."
  else
    echo "Installed, but the shell has not picked it up yet. Run:"
    echo "  omarchy-shell shell rescanPlugins && omarchy plugin enable $ID && omarchy bar put $ID --section right"
  fi
else
  echo "Installed to $DST. Run: omarchy plugin enable $ID"
fi

echo
echo "udev rule (needed once, or use the panel's Grant access button):"
echo "  sudo cp $DST/udev/60-aula-f75.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=hidraw"
