#!/bin/bash
set -euo pipefail

core_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_sources=("$core_repo_root"/SwiftPlayer/PlaybackCore/*.swift)
core_check_cache="$(mktemp -d "${TMPDIR:-/tmp}/SwiftPlayerCore-check.XXXXXX")"
trap 'rm -rf "$core_check_cache"' EXIT

if grep -Eq '^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)?import[[:space:]]+(AppKit|UIKit|SwiftUI|AVKit|RealityKit)([[:space:].]|$)' "${core_sources[@]}"; then
    echo "PlaybackCore must not import a presentation framework." >&2
    exit 1
fi

check_core() {
    local core_sdk="$1" core_target="$2" core_label="$3"
    local core_sdk_path
    core_sdk_path="$(xcrun --sdk "$core_sdk" --show-sdk-path)"
    xcrun swiftc -typecheck -swift-version 5 -default-isolation MainActor \
        -enable-upcoming-feature NonisolatedNonsendingByDefault \
        -enable-upcoming-feature InferIsolatedConformances \
        -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
        -target "$core_target" -sdk "$core_sdk_path" \
        -module-cache-path "$core_check_cache/$core_label" "${core_sources[@]}"
    printf '%s: PASS\n' "$core_label"
}

check_core macosx arm64-apple-macos13.0 macOS-arm64
check_core macosx x86_64-apple-macos13.0 macOS-Intel
check_core iphoneos arm64-apple-ios17.0 iOS-iPadOS
check_core xros arm64-apple-xros1.0 visionOS
