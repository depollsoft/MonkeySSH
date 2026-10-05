#!/usr/bin/env bash
# Android re-signing shared by build-deploy.yml and the Internal App Sharing job.
#
#   android_signing.sh jarsign <in.aab> <out.aab> <keystore> [alias storepass keypass]
#   android_signing.sh universal-apk <in.aab> <out.apk> <keystore> [alias storepass keypass]
#
# A keystore of `debug` selects the Android debug key, created on first use.
set -euo pipefail

BUNDLETOOL_VERSION='1.18.3'

if [ $# -ne 4 ] && [ $# -ne 7 ]; then
  sed -n '4,5p' "$0" >&2
  exit 2
fi
command="$1" input="$2" output="$3" keystore="$4"
alias="${5:-}" storepass="${6:-}" keypass="${7:-}"

if [ "$keystore" = debug ]; then
  keystore="$HOME/.android/debug.keystore" alias=androiddebugkey storepass=android keypass=android
  if [ ! -f "$keystore" ]; then
    mkdir -p "$(dirname "$keystore")"
    keytool -genkeypair -keystore "$keystore" -storepass android -alias androiddebugkey \
      -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US"
  fi
fi

case "$command" in
  jarsign)
    jarsigner -sigalg SHA256withRSA -digestalg SHA-256 -keystore "$keystore" \
      -storepass "$storepass" -keypass "$keypass" -signedjar "$output" "$input" "$alias"
    jarsigner -verify "$output"
    ;;
  universal-apk)
    work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/universal-apk.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    curl --fail --location --retry 3 --output "$work/bundletool.jar" \
      "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
    java -jar "$work/bundletool.jar" build-apks --bundle="$input" --output="$work/app.apks" \
      --mode=universal --ks="$keystore" --ks-pass="pass:$storepass" \
      --ks-key-alias="$alias" --key-pass="pass:$keypass" --overwrite
    unzip -q "$work/app.apks" universal.apk -d "$work"
    mkdir -p "$(dirname "$output")"
    mv "$work/universal.apk" "$output"
    ;;
  *)
    sed -n '4,5p' "$0" >&2
    exit 2
    ;;
esac
