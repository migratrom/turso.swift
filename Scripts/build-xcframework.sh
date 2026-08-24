#!/bin/bash
set -euo pipefail

TURSO_REVISION="c5816b5f5f5d2568e551a746f92f893003e55234"
REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$(mktemp -d)"
SOURCE_ROOT="$BUILD_ROOT/turso-$TURSO_REVISION"
ARTIFACT_ROOT="$BUILD_ROOT/artifacts"

cleanup() {
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

curl -L "https://github.com/tursodatabase/turso/archive/$TURSO_REVISION.tar.gz" \
    -o "$BUILD_ROOT/turso.tar.gz"
tar -xzf "$BUILD_ROOT/turso.tar.gz" -C "$BUILD_ROOT"

pushd "$SOURCE_ROOT" >/dev/null
rustup target add \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios

for target in \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios
do
    if [[ "$target" == *"apple-darwin" ]]; then
        MACOSX_DEPLOYMENT_TARGET=13.0 cargo build \
            --package turso_sync_sdk_kit \
            --profile lib-release \
            --target "$target"
    else
        IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build \
            --package turso_sync_sdk_kit \
            --profile lib-release \
            --target "$target"
    fi
done
popd >/dev/null

mkdir -p "$ARTIFACT_ROOT/headers"
cp "$SOURCE_ROOT/sdk-kit/turso.h" "$ARTIFACT_ROOT/headers/turso.h"
cp "$SOURCE_ROOT/sync/sdk-kit/turso_sync.h" "$ARTIFACT_ROOT/headers/turso_sync.h"
cp "$REPOSITORY_ROOT/Vendor/module.modulemap" "$ARTIFACT_ROOT/headers/module.modulemap"

lipo -create \
    "$SOURCE_ROOT/target/aarch64-apple-darwin/lib-release/libturso_sync_sdk_kit.a" \
    "$SOURCE_ROOT/target/x86_64-apple-darwin/lib-release/libturso_sync_sdk_kit.a" \
    -output "$ARTIFACT_ROOT/libCTurso-macos.a"
lipo -create \
    "$SOURCE_ROOT/target/aarch64-apple-ios-sim/lib-release/libturso_sync_sdk_kit.a" \
    "$SOURCE_ROOT/target/x86_64-apple-ios/lib-release/libturso_sync_sdk_kit.a" \
    -output "$ARTIFACT_ROOT/libCTurso-ios-simulator.a"
cp \
    "$SOURCE_ROOT/target/aarch64-apple-ios/lib-release/libturso_sync_sdk_kit.a" \
    "$ARTIFACT_ROOT/libCTurso-ios.a"

xcodebuild -create-xcframework \
    -library "$ARTIFACT_ROOT/libCTurso-macos.a" \
    -headers "$ARTIFACT_ROOT/headers" \
    -library "$ARTIFACT_ROOT/libCTurso-ios.a" \
    -headers "$ARTIFACT_ROOT/headers" \
    -library "$ARTIFACT_ROOT/libCTurso-ios-simulator.a" \
    -headers "$ARTIFACT_ROOT/headers" \
    -output "$ARTIFACT_ROOT/CTurso.xcframework"

rm -rf "$REPOSITORY_ROOT/Vendor/CTurso.xcframework"
mv "$ARTIFACT_ROOT/CTurso.xcframework" "$REPOSITORY_ROOT/Vendor/CTurso.xcframework"
