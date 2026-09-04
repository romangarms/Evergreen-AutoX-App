#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

PROJECT="Evergreen AutoX App iOS.xcodeproj"
SCHEME="Evergreen AutoX App iOS"
PBXPROJ="$PROJECT/project.pbxproj"
BUILD_DIR=build
TEAM_ID=98GQ88N9TN

usage() {
    cat <<USAGE
Usage: ./deploy.sh [options] [build|patch|minor|major|X.Y.Z]

Ships a new TestFlight build: bumps the version, archives a Release build,
uploads it to App Store Connect, then offers to commit and tag.

  build|patch|minor|major|X.Y.Z
                 How to bump the version (see ./bump-version.sh). Asked
                 interactively when omitted.
  --skip-bump    Upload the version already in the project.
  --no-upload    Archive only; leaves the .xcarchive in $BUILD_DIR/.
  -y             Don't ask before continuing with uncommitted changes.
  help           Show this message.

Uploading uses the Apple ID signed in to Xcode (Settings > Accounts). To use
an App Store Connect API key instead, export ASC_KEY_ID, ASC_ISSUER_ID and
ASC_KEY_PATH (path to the AuthKey_XXXX.p8 file).
USAGE
}

bump=""
skip_bump=false
upload=true
assume_yes=false
for arg in "$@"; do
    case "$arg" in
        --skip-bump) skip_bump=true ;;
        --no-upload) upload=false ;;
        -y) assume_yes=true ;;
        help|-h|--help) usage; exit 0 ;;
        build|patch|minor|major|[0-9]*.[0-9]*) bump=$arg ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

confirm() {
    $assume_yes && return 0
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]]
}

setting() {
    sed -n "s/^[[:space:]]*$1 = \(.*\);/\1/p" "$PBXPROJ" | head -n 1
}

step() {
    echo
    echo "==> $*"
}

if ! command -v xcodebuild >/dev/null; then
    echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

if [ -n "$(git status --porcelain -- . ':!*.xcuserstate')" ]; then
    echo "Uncommitted changes in the iOS project:"
    git status --short -- . ':!*.xcuserstate'
    confirm "Continue anyway?" || exit 1
fi

if ! $skip_bump; then
    step "Version"
    ./bump-version.sh $bump
fi

version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
archive="$BUILD_DIR/EvergreenAutoX-$version-$build.xcarchive"
log="$BUILD_DIR/deploy-$version-$build.log"
mkdir -p "$BUILD_DIR"
: > "$log"

step "Archiving $version ($build) (log: $log)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    -quiet >>"$log" 2>&1 || {
    echo "Archive failed. Last lines of $log:" >&2
    tail -n 30 "$log" >&2
    exit 1
}
echo "Archived to $archive"

if ! $upload; then
    echo "Skipping upload (--no-upload)."
    exit 0
fi

step "Uploading to App Store Connect"
export_options="$BUILD_DIR/ExportOptions.plist"
cat >"$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

auth_args=()
if [ -n "$ASC_KEY_ID" ]; then
    auth_args=(
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
        -authenticationKeyPath "$ASC_KEY_PATH"
    )
fi

xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$BUILD_DIR/export-$version-$build" \
    -allowProvisioningUpdates \
    "${auth_args[@]}" >>"$log" 2>&1 || {
    echo "Upload failed. Last lines of $log:" >&2
    tail -n 30 "$log" >&2
    echo >&2
    echo "The version bump is still in $PBXPROJ; revert it with: git checkout -- '$PBXPROJ'" >&2
    exit 1
}
echo "Uploaded $version ($build). It will appear under TestFlight in App Store Connect once processed (usually 5-15 min)."

step "Git"
tag="ios-v$version-$build"
if confirm "Commit the version bump and tag $tag?"; then
    git add "$PBXPROJ"
    git commit -m "iOS $version ($build)" -- "$PBXPROJ"
    git tag "$tag"
    if confirm "Push to origin?"; then
        git push origin HEAD "$tag"
    fi
fi
