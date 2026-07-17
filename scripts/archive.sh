#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
distribution="${1:-app-store}"
archive_path="${project_root}/build/Archive/Durepo.xcarchive"

case "$distribution" in
  app-store)
    export_options="${project_root}/Config/ExportOptions-AppStore.plist"
    export_path="${project_root}/build/Export/AppStore"
    ;;
  developer-id)
    export_options="${project_root}/Config/ExportOptions-DeveloperID.plist"
    export_path="${project_root}/build/Export/DeveloperID"
    ;;
  *)
    print -u2 "usage: $0 [app-store|developer-id]"
    exit 64
    ;;
esac

cd "$project_root"
xcodegen generate
xcodebuild -project Durepo.xcodeproj \
  -scheme Durepo \
  -configuration Release \
  -archivePath "$archive_path" \
  clean archive

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

print "Exported to $export_path"
