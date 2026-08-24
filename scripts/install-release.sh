#!/bin/zsh
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
app_source="${package_dir}/MailBridge.app"
skill_source="${package_dir}/email-triage"
app_dir="${MAILBRIDGE_APP_DIR:-${HOME}/Applications/MailBridge.app}"
app_root="$(/usr/bin/dirname "${app_dir}")"
skill_root="${CODEX_HOME:-${HOME}/.codex}/skills"
skill_dir="${skill_root}/email-triage"

if [[ ! -d "${app_source}" || ! -d "${skill_source}" ]]; then
  echo "Release package is incomplete: MailBridge.app or email-triage is missing." >&2
  exit 1
fi

/bin/mkdir -p "${app_root}" "${skill_root}"
/usr/bin/ditto "${app_source}" "${app_dir}"
/usr/bin/ditto "${skill_source}" "${skill_dir}"
/bin/chmod 755 "${app_dir}/Contents/MacOS/MailBridge"

echo "Installed app: ${app_dir}"
echo "Installed skill: ${skill_dir}"
echo "Next, grant Apple Mail automation access:"
echo "  printf '%s' '{\"action\":\"setup\"}' | '${app_dir}/Contents/MacOS/MailBridge'"
