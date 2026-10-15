#!/bin/zsh
set -euo pipefail
converter_dir="${HOME}/Library/Application Support/MailTriage/converter"
if [[ ! -x "${converter_dir}/bin/python" ]]; then
  uv venv --python 3.12 "${converter_dir}"
fi
uv pip install --no-cache --python "${converter_dir}/bin/python" 'markitdown[pdf,docx,xlsx]==0.1.8'
echo "Installed local attachment converter: ${converter_dir}"
