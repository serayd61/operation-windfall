#!/bin/sh
# Builds the signed release bundle. Needs JDK 21, the Android SDK and the upload keystore.
set -e
cd "$(dirname "$0")"
K="$HOME/.operation-windfall-keys"
val() { grep "^$1" "$K/passwords.txt" | sed -E 's/^[^:=]*[:=][[:space:]]*//'; }
export JAVA_HOME="${JAVA_HOME:-$(ls -d "$HOME"/.bubblewrap/jdk21/*/Contents/Home | head -1)}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export WINDFALL_KEYSTORE="$K/upload.keystore" WINDFALL_STORE_PASSWORD="$(val KEYSTORE_PASSWORD)" WINDFALL_KEY_PASSWORD="$(val KEY_PASSWORD)" WINDFALL_KEY_ALIAS="$(val KEY_ALIAS)"
npm run sync
cd android && ./gradlew --no-daemon -q bundleRelease assembleRelease
