#!/bin/zsh
set -euo pipefail

bridge="${HOME}/Applications/MailBridge.app/Contents/MacOS/MailBridge"
if [[ ! -x "${bridge}" ]]; then
  echo "MailBridge is not installed: ${bridge}" >&2
  exit 1
fi

echo '{"action":"state.record","confirmed":true,"state":{"flaggingEnabled":true}}' | "${bridge}"
