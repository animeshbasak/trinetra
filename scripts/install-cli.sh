#!/usr/bin/env bash
# Build the trinetra CLI and install it to ~/.local/bin/trinetra.
set -euo pipefail
cd "$(dirname "$0")/../Packages/TrinetraCore"
swift build -c release --product trinetra
mkdir -p "$HOME/.local/bin"
install -m 0755 .build/release/trinetra "$HOME/.local/bin/trinetra"
echo "Installed $HOME/.local/bin/trinetra"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: add ~/.local/bin to your PATH (e.g. in ~/.zshrc)";;
esac
"$HOME/.local/bin/trinetra" status || true
