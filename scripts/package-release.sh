#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 v1.0.0" >&2
  exit 1
fi

version="${1#v}"
if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Version must use semantic versioning, for example v1.0.0." >&2
  exit 1
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
arch="$(/usr/bin/uname -m)"
case "${arch}" in
  arm64) release_arch="arm64" ;;
  x86_64) release_arch="x86_64" ;;
  *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
esac

binary="${project_dir}/.build/release/MailBridge"
if [[ ! -x "${binary}" ]]; then
  /usr/bin/swift build -c release --package-path "${project_dir}"
fi

staging_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apple-mail-triage.XXXXXX")"
trap '/bin/rm -rf "${staging_root}"' EXIT
package_name="Apple-Mail-Triage-${version}-macOS-${release_arch}"
package_dir="${staging_root}/${package_name}"
app_dir="${package_dir}/MailBridge.app"
output_dir="${project_dir}/dist"
archive="${output_dir}/${package_name}.zip"

/bin/mkdir -p "${app_dir}/Contents/MacOS" "${output_dir}"
/usr/bin/ditto "${binary}" "${app_dir}/Contents/MacOS/MailBridge"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
/bin/chmod 755 "${app_dir}/Contents/MacOS/MailBridge"
/usr/bin/codesign --force --deep --sign - "${app_dir}"
/usr/bin/ditto "${project_dir}/skill/email-triage" "${package_dir}/email-triage"
/usr/bin/ditto "${project_dir}/scripts/install-release.sh" "${package_dir}/install.sh"
/usr/bin/ditto "${project_dir}/docs/使用说明.md" "${package_dir}/README.zh-CN.md"
/usr/bin/ditto "${project_dir}/LICENSE" "${package_dir}/LICENSE"
/bin/chmod 755 "${package_dir}/install.sh"

/bin/rm -f "${archive}" "${archive}.sha256"
/usr/bin/ditto -c -k --norsrc --keepParent "${package_dir}" "${archive}"
(cd "${output_dir}" && /usr/bin/shasum -a 256 "${package_name}.zip" > "${package_name}.zip.sha256")

echo "Created ${archive}"
echo "Created ${archive}.sha256"
