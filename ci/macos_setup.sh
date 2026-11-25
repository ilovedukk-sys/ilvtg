#!/bin/bash
# Prepare a GitHub-hosted macOS runner for the Telegram-iOS Bazel build.
set -euo pipefail

required_xcode="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["xcode"])' "$1/versions.json")"
xcode_app="/Applications/Xcode_${required_xcode}.app"
if [ -d "$xcode_app" ]; then
    sudo xcode-select --switch "$xcode_app/Contents/Developer"
else
    echo "::error::Xcode ${required_xcode} is not installed on this runner. Installed:"
    ls -d /Applications/Xcode*.app || true
    exit 1
fi
xcodebuild -version
sw_vers

# Third-party genrules run with PATH=/bin:/usr/bin:/usr/local/bin (no Homebrew, no /usr/sbin).
if ! command -v ccache >/dev/null 2>&1; then
    brew install ccache
fi
sudo mkdir -p /usr/local/bin
if ! env -i PATH=/bin:/usr/bin:/usr/local/bin ccache --version >/dev/null 2>&1; then
    sudo ln -sf "$(command -v ccache)" /usr/local/bin/ccache
fi
if ! env -i PATH=/bin:/usr/bin:/usr/local/bin sysctl -n hw.ncpu >/dev/null 2>&1; then
    sudo ln -sf /usr/sbin/sysctl /usr/local/bin/sysctl
fi

# Since Xcode 26 the Metal compiler is a separate download; Telegram ships Metal shaders.
xcodebuild -downloadComponent MetalToolchain
probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void probe(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }\n' > "$probe/p.metal"
xcrun --sdk iphoneos metal -c -target air64-apple-ios15.0 "$probe/p.metal" -o "$probe/p.air"
echo "Toolchain ready."
