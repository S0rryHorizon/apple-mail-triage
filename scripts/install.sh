#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${HOME}/Applications/MailBridge.app"
skill_root="${CODEX_HOME:-${HOME}/.codex}/skills"
skill_dir="${skill_root}/email-triage"

/usr/bin/swift build -c release --package-path "${project_dir}"
/bin/mkdir -p "${app_dir}/Contents/MacOS" "${skill_dir}"
/usr/bin/ditto "${project_dir}/.build/release/MailBridge" "${app_dir}/Contents/MacOS/MailBridge"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
/bin/chmod 755 "${app_dir}/Contents/MacOS/MailBridge"
/usr/bin/codesign --force --deep --sign - "${app_dir}"
/usr/bin/ditto "${project_dir}/skill/email-triage" "${skill_dir}"

echo "Installed app: ${app_dir}"
echo "Installed skill: ${skill_dir}"
echo "Run setup when ready:"
echo "  echo '{\"action\":\"setup\"}' | '${app_dir}/Contents/MacOS/MailBridge'"
