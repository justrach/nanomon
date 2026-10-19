#!/bin/sh
# Notarize locally signed assets on a draft release, using CI's API key.
# The signing private key stays on the machine that built the app.
set -eu

tag="$1"
python3 -c 'import re, sys; assert re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", sys.argv[1])' "$tag"
repo="${GITHUB_REPOSITORY:-justrach/nanomon}"
[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" = true ]
version="${tag#v}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
cd "$work"

gh release download "$tag" --repo "$repo" --pattern nanomon-macos-arm64.zip --pattern nanomon-macos-arm64.dmg
zip=nanomon-macos-arm64.zip
dmg=nanomon-macos-arm64.dmg
ditto -x -k "$zip" .
bundle=nanomon.app
codesign --verify --strict "$bundle"
# Ad-hoc signatures cannot be notarized; don't silently downgrade a release.
team="$(codesign -dv --verbose=2 "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$team" ] && [ "$team" != 'not set' ]
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist")" = "$version" ]
python3 "$script_dir/check-launch.py" "$bundle"

umask 077
printf '%s' "$AC_API_KEY_P8" > api-key.p8
notarize() {
  # Keep submission identifiers and API diagnostics out of public logs.
  if ! xcrun notarytool submit "$1" --key api-key.p8 --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" --wait --output-format json > notary-result.json 2> notary-error.txt; then
    echo 'Apple notarization request failed.' >&2
    exit 1
  fi
  python3 -c 'import json; assert json.load(open("notary-result.json"))["status"] == "Accepted", "Apple rejected the submission"'
}

staple() {
  attempt=1
  while :; do
    if xcrun stapler staple "$1" > staple-result.txt 2>&1; then
      xcrun stapler validate "$1" >/dev/null
      return
    else
      status=$?
    fi
    # Accepted tickets can take a little longer to reach Apple's CDN.
    if [ "$status" -ne 68 ] || [ "$attempt" -ge 4 ]; then
      echo "Ticket stapling failed (exit $status)." >&2
      exit "$status"
    fi
    echo 'Waiting for the accepted notarization ticket to become available.'
    sleep 10
    attempt=$((attempt + 1))
  done
}

echo 'Notarizing the app update.'
notarize "$zip"
echo 'Stapling the app ticket.'
staple "$bundle"
# The update zip carries the stapled app. The disk image has its own ticket,
# which covers the signed app inside it too.
rm "$zip"
ditto -c -k --keepParent "$bundle" "$zip"
echo 'Notarizing the disk image.'
notarize "$dmg"
echo 'Stapling the disk image ticket.'
staple "$dmg"
hdiutil verify "$dmg" >/dev/null
spctl --assess --type execute "$bundle"

shasum -a 256 "$dmg" > "$dmg.sha256"
sum="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
printf '{"version":"%s","files":{"%s":{"sha256":"%s"}}}\n' "$version" "$zip" "$sum" > manifest.json
gh release upload "$tag" "$dmg" "$dmg.sha256" "$zip" manifest.json --repo "$repo" --clobber
echo 'Notarized assets uploaded; the release remains a draft.'
