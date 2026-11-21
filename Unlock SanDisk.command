#!/bin/zsh
# Double-click this in Finder. It runs the full, safe chain:
# hardware unlock if needed -> APFS unlock if needed -> mount -> open in Finder.
cd "$(dirname "$0")" || exit 1
./open-develop
rc=$?
echo
if [ $rc -ne 0 ]; then
  echo "Could not open develop (exit $rc). Nothing was erased."
fi
read -r "?Press Return to close..."
