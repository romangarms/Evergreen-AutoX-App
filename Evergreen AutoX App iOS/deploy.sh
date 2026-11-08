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
       ./deploy.sh release
       ./deploy.sh notes [TAG]
       ./deploy.sh set-key

Ships a new TestFlight build: bumps the version, archives a Release build,
exports an .ipa, uploads it to App Store Connect, then commits, tags
(ios-vX.Y-N) and creates a GitHub release with the .ipa attached.

  build|patch|minor|major|X.Y.Z
                 How to bump the version (see ./bump-version.sh). Asked
                 interactively when omitted.
  --skip-bump    Upload the version already in the project.
  --no-upload    Archive and export the .ipa only; no upload, no release.
  --notes=FILE   Use FILE as the release notes instead of asking for them.
  -y             Don't ask before continuing with uncommitted changes or
                 before the git/GitHub step, and publish the drafted notes
                 without opening the editor.
  release        Only do the git/GitHub step for the version in the project,
                 using the archive already in $BUILD_DIR/ (re-exports the .ipa
                 if needed). For retrying after a failed release step.
  notes [TAG]    Rewrite an existing release's notes in the editor (default:
                 the version in the project).
  set-key        Set or change the App Store Connect API key used to upload.

Release notes are what users read on the website's /updates page. Before the
release is created, \$VISUAL/\$EDITOR (vi if unset) opens a draft built from
the commit subjects since the last release; rewrite it as one "- " line per
change a user would notice. An empty file stops before the release is created;
./deploy.sh release picks up from there.
  help           Show this message.

Uploading needs an App Store Connect API key (xcodebuild cannot use the
Apple ID signed in to Xcode). The first upload asks for one and saves it to
$KEY_ENV (gitignored); the .p8 file is copied to $KEY_DIR.
Environment variables ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH override it.
The GitHub release uses the gh CLI (brew install gh; gh auth login).
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

fail() {
    echo "$1. Last lines of $log:" >&2
    tail -n 30 "$log" >&2
    exit 1
}

write_export_options() {
    cat >"$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$2</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
}

do_archive() {
    step "Archiving $version ($build) (log: $log)"
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        -quiet >>"$log" 2>&1 || fail "Archive failed"
    echo "Archived to $archive"
}

do_export_ipa() {
    step "Exporting .ipa"
    write_export_options "$BUILD_DIR/ExportOptions-export.plist" export
    rm -rf "$export_dir"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-export.plist" \
        -exportPath "$export_dir" \
        -allowProvisioningUpdates >>"$log" 2>&1 || fail "Export failed"
    mv "$export_dir"/*.ipa "$ipa"
    echo "Exported $ipa"
}

do_upload() {
    step "Uploading to App Store Connect"
    write_export_options "$BUILD_DIR/ExportOptions-upload.plist" upload
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-upload.plist" \
        -exportPath "$BUILD_DIR/upload-$version-$build" \
        -allowProvisioningUpdates \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        -authenticationKeyPath "$ASC_KEY_PATH" >>"$log" 2>&1 || {
        echo >&2
        echo "The version bump is still in $PBXPROJ; revert it with: git checkout -- '$PBXPROJ'" >&2
        fail "Upload failed"
    }
    echo "Uploaded $version ($build). It will appear under TestFlight in App Store Connect once processed (usually 5-15 min)."
}

draft_notes() {
    local previous
    previous=$(git describe --tags --abbrev=0 --match 'ios-v*' "$tag^" 2>/dev/null || true)
    [ -n "$previous" ] || return 0
    git log --no-merges --format='- %s' "$previous..$tag" -- .. |
        grep -viE '^- (ios|android) [0-9]|screenshot' || true
}

strip_comments() {
    local cleaned
    cleaned=$(grep -v '^#' "$1" | sed -e '/./,$!d')
    printf '%s\n' "$cleaned" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$1"
}

edit_notes() {
    local file=$1 label=$2 body
    body=$(cat "$file")
    cat >"$file" <<HEADER
# Release notes for $label, shown to users on the website's /updates page.
# One "- " line per change a user would notice; drop developer-only lines.
# Lines starting with # are removed. Save an empty file to stop.

$body
HEADER
    ${VISUAL:-${EDITOR:-vi}} "$file"
    strip_comments "$file"
    if [ ! -s "$file" ]; then
        echo "Release notes are empty; stopping." >&2
        return 1
    fi
}

edit_release_notes() {
    local target=$1 file
    command -v gh >/dev/null || { echo "gh CLI not found; install with: brew install gh && gh auth login" >&2; exit 1; }
    mkdir -p "$BUILD_DIR"
    file="$BUILD_DIR/notes-$target.md"
    gh release view "$target" --json body -q .body >"$file"
    edit_notes "$file" "$target" || exit 1
    gh release edit "$target" --notes-file "$file"
    echo "Updated notes for $target: $(gh release view "$target" --json url -q .url)"
}

do_release() {
    step "Git / GitHub release $tag"
    if ! command -v gh >/dev/null; then
        echo "gh CLI not found; install with: brew install gh && gh auth login" >&2
        echo "Skipping tag and release. Run ./deploy.sh release once gh is set up." >&2
        return 1
    fi
    confirm "Commit the project file, tag $tag, push, and create a GitHub release with the .ipa?" || return 0

    if ! git diff --quiet -- "$PBXPROJ" || ! git diff --cached --quiet -- "$PBXPROJ"; then
        git add "$PBXPROJ"
        git commit -m "iOS $version ($build)" -- "$PBXPROJ"
    fi
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "Tag $tag already exists; reusing it."
    else
        git tag -a "$tag" -m "iOS $version ($build)"
    fi
    git push origin HEAD "$tag"

    if gh release view "$tag" >/dev/null 2>&1; then
        gh release upload "$tag" "$ipa" --clobber
        echo "Release $tag already existed; replaced its .ipa."
    else
        notes="$BUILD_DIR/notes-$version-$build.md"
        if [ -n "$notes_file" ]; then
            cp "$notes_file" "$notes"
        elif [ ! -s "$notes" ]; then
            draft_notes >"$notes"
        fi
        if [ -z "$notes_file" ] && ! $assume_yes; then
            edit_notes "$notes" "$tag" || return 1
        fi
        strip_comments "$notes"
        [ -s "$notes" ] || echo "- TestFlight build $version ($build)" >"$notes"
        gh release create "$tag" "$ipa" \
            --title "iOS $version ($build)" \
            --notes-file "$notes"
    fi
    echo "Release: $(gh release view "$tag" --json url -q .url)"
}

bump=""
skip_bump=false
upload=true
assume_yes=false
mode=deploy
notes_file=""
notes_tag=""
for arg in "$@"; do
    if [ "$mode" = notes ] && [ -z "$notes_tag" ] && [[ "$arg" != -* ]]; then
        notes_tag=$arg
        continue
    fi
    case "$arg" in
        --notes=*)
            notes_file=${arg#--notes=}
            [ -f "$notes_file" ] || { echo "No file at $notes_file" >&2; exit 1; }
            ;;
        --skip-bump) skip_bump=true ;;
        --no-upload) upload=false ;;
        -y) assume_yes=true ;;
        release) mode=release ;;
        notes) mode=notes ;;
        set-key) set_key; exit 0 ;;
        help|-h|--help) usage; exit 0 ;;
        build|patch|minor|major|[0-9]*.[0-9]*) bump=$arg ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "$mode" = notes ]; then
    edit_release_notes "${notes_tag:-ios-v$(setting MARKETING_VERSION)-$(setting CURRENT_PROJECT_VERSION)}"
    exit
fi

if ! command -v xcodebuild >/dev/null; then
    echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

if [ "$mode" = deploy ]; then
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
fi

version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
tag="ios-v$version-$build"
archive="$BUILD_DIR/EvergreenAutoX-$version-$build.xcarchive"
export_dir="$BUILD_DIR/export-$version-$build"
ipa="$BUILD_DIR/EvergreenAutoX-$version-$build.ipa"
log="$BUILD_DIR/deploy-$version-$build.log"
mkdir -p "$BUILD_DIR"

if [ "$mode" = release ]; then
    [ -d "$archive" ] || { echo "No archive at $archive; run ./deploy.sh --skip-bump first." >&2; exit 1; }
    [ -f "$ipa" ] || do_export_ipa
    do_release
    exit
fi

: > "$log"
do_archive
do_export_ipa
$upload || { echo "Skipping upload and release (--no-upload)."; exit 0; }
do_upload
do_release
