#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
clang -O2 -Wall -Wextra -arch arm64 \
  -o sandisk-unlock sandisk-unlock.c \
  -framework IOKit -framework CoreFoundation
echo "built: $(pwd)/sandisk-unlock"
file sandisk-unlock
