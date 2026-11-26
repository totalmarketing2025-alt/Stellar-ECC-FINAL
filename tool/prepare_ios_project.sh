#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS project generation requires macOS with Xcode installed." >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is required. Install the project-pinned Flutter SDK first." >&2
  exit 1
fi

# The repository contains selected Runner resources but not the generated
# Xcode project. Generate only the missing iOS platform files; do not use
# --overwrite because it would replace the customized Runner files.
flutter create \
  --platforms=ios \
  --org=ecc.stellar \
  --project-name=app \
  --no-pub \
  .

project_file="ios/Runner.xcodeproj/project.pbxproj"
if [[ ! -f "$project_file" ]]; then
  echo "Flutter did not generate $project_file." >&2
  exit 1
fi

if ! grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = ecc.stellar.app;' "$project_file"; then
  echo "Generated Runner bundle identifier does not match ecc.stellar.app." >&2
  exit 1
fi

for required_file in \
  ios/Runner/AppDelegate.swift \
  ios/Runner/Info.plist \
  ios/Runner/Runner.entitlements \
  ios/Flutter/Debug.xcconfig \
  ios/Flutter/Release.xcconfig; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required iOS file is missing: $required_file" >&2
    exit 1
  fi
done

echo "iOS Xcode project is generated and uses bundle ID ecc.stellar.app."
