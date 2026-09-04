#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

PROJECT="Evergreen AutoX App iOS.xcodeproj"
SCHEME="Evergreen AutoX App iOS"
PBXPROJ="$PROJECT/project.pbxproj"
BUILD_DIR=build
TEAM_ID=98GQ88N9TN
KEY_ENV=.deploy.env
KEY_DIR="$HOME/.appstoreconnect/private_keys"

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
  set-key        Set or change the App Store Connect API key used to upload.
  help           Show this message.

Uploading needs an App Store Connect API key (xcodebuild cannot use the
Apple ID signed in to Xcode). The first upload asks for one and saves it to
$KEY_ENV (gitignored); the .p8 file is copied to $KEY_DIR.
Environment variables ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH override it.
USAGE
}

set_key() {
    cat <<KEYHELP

Create a key at https://appstoreconnect.apple.com/access/integrations/api
(Team Keys > +, role "App Manager"). Download the AuthKey_XXXXXXXXXX.p8 file
(Apple only lets you download it once) and note the Key ID and Issuer ID
shown on that page.

KEYHELP
    read -r -p "Key ID: " key_id
    read -r -p "Issuer ID: " issuer_id
    read -r -p "Path to .p8 file: " key_src
    key_src=${key_src%"${key_src##*[! ]}"}
    key_src=${key_src#[\'\"]}
    key_src=${key_src%[\'\"]}
    key_src=${key_src//\\ / }
    key_src=${key_src/#\~/$HOME}
    [ -f "$key_src" ] || { echo "No file at $key_src" >&2; exit 1; }
    mkdir -p "$KEY_DIR"
    key_path="$KEY_DIR/AuthKey_$key_id.p8"
    cp "$key_src" "$key_path"
    chmod 600 "$key_path"
    cat >"$KEY_ENV" <<ENV
ASC_KEY_ID='$key_id'
ASC_ISSUER_ID='$issuer_id'
ASC_KEY_PATH='$key_path'
ENV
    echo "Saved to $KEY_ENV and $key_path"
}

load_key() {
    if [ -z "$ASC_KEY_ID" ] && [ -f "$KEY_ENV" ]; then
        # shellcheck disable=SC1090
        . "./$KEY_ENV"
    fi
    if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY_PATH" ]; then
        echo "No App Store Connect API key configured."
        set_key
        # shellcheck disable=SC1090
        . "./$KEY_ENV"
    fi
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
        set-key) set_key; exit 0 ;;
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

$upload && load_key

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

xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$BUILD_DIR/export-$version-$build" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -authenticationKeyPath "$ASC_KEY_PATH" >>"$log" 2>&1 || {
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
