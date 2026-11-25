#!/bin/zsh
set -euo pipefail

if [[ -z "${ACTION_KEY:-}" || $# -lt 1 ]]; then
  exit 1
fi

first_path="$1"
if [[ -d "$first_path" ]]; then
  base_dir="$first_path"
else
  base_dir="${first_path:h}"
fi

urlencode() {
  /usr/bin/python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

encoded_base=$(urlencode "$base_dir")
url="reposhell://quickaction?action=$(urlencode "$ACTION_KEY")&baseDir=${encoded_base}"

if [[ "${ACCEPT_FILES:-0}" == "1" ]]; then
  for item in "$@"; do
    encoded_item=$(urlencode "$item")
    url+="&path=${encoded_item}"
  done
fi

/usr/bin/open "$url"
