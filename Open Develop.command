#!/bin/zsh
# Double-click this in Finder to open the SanDisk "develop" volume.
cd "$(dirname "$0")" || exit 1
./open-develop
rc=$?
echo
if [ $rc -ne 0 ]; then
  echo "Could not open develop (exit $rc). Nothing was erased."
fi
read -r "?Press Return to close..."
