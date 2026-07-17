#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 <path-to-app-or-archive.zip> <keychain-profile>"
  exit 64
fi

artifact_path="$1"
keychain_profile="$2"

if [[ ! -e "$artifact_path" ]]; then
  print -u2 "artifact not found: $artifact_path"
  exit 66
fi

submission_path="$artifact_path"
temporary_zip=""
temporary_directory=""

if [[ "$artifact_path" == *.app ]]; then
  temporary_directory="$(mktemp -d "${TMPDIR%/}/Durepo-notary.XXXXXX")"
  temporary_zip="$temporary_directory/Durepo.zip"
  ditto -c -k --keepParent "$artifact_path" "$temporary_zip"
  submission_path="$temporary_zip"
fi

cleanup() {
  if [[ -n "$temporary_zip" && -e "$temporary_zip" ]]; then
    rm "$temporary_zip"
  fi
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rmdir "$temporary_directory"
  fi
}
trap cleanup EXIT

xcrun notarytool submit "$submission_path" \
  --keychain-profile "$keychain_profile" \
  --wait

if [[ "$artifact_path" == *.app ]]; then
  xcrun stapler staple "$artifact_path"
  xcrun stapler validate "$artifact_path"
  spctl --assess --type execute --verbose=2 "$artifact_path"
fi
