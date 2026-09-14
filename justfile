project := "Voice.xcodeproj"
scheme := "Voice"
# Xcode's explicit-module cache is configuration-sensitive for the MLX/NIO C
# shims, so Debug and Release must not share DerivedData.
debug_derived_data := ".build/DerivedData-Debug"
release_derived_data := ".build/DerivedData-Release"
# The CLI tools are separate schemes; building them into the app's DerivedData
# changes the build parameters enough to break the explicit-module scan.
cli_derived_data := ".build/DerivedData-CLI"
source_packages := ".build/SourcePackages"
destination := "platform=macOS,arch=arm64e"

default: build

generate:
    xcodegen generate

build: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build

test: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES test

release: generate
    #!/usr/bin/env bash
    set -euo pipefail
    build=(
        ./scripts/xcbuild.sh -quiet
        -project "{{project}}"
        -scheme "{{scheme}}"
        -configuration Release
        -destination "{{destination}}"
        -derivedDataPath "{{release_derived_data}}"
        -clonedSourcePackagesDirPath "{{source_packages}}"
        -onlyUsePackageVersionsFromResolvedFile
        ARCHS=arm64e
        ONLY_ACTIVE_ARCH=YES
    )
    if security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eq '^[[:space:]]*[1-9][0-9]* valid identities found$'; then
        echo "Building a signed Release app with an installed identity."
        "${build[@]}" build
    else
        echo "Warning: no valid code-signing identity found; building an ad-hoc Release app." >&2
        echo "Use 'just release-signed' when permission identity or Keychain behavior matters." >&2
        "${build[@]}" \
            CODE_SIGN_STYLE=Manual \
            DEVELOPMENT_TEAM= \
            CODE_SIGN_IDENTITY=- \
            PROVISIONING_PROFILE_SPECIFIER= \
            build
    fi

release-signed: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{release_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build

# Build the signed Release app, install it into /Applications, and relaunch.
install-app: release-signed
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{release_derived_data}}/Build/Products/Release/Voice.app"
    if [[ ! -d "$app" ]]; then
        echo "error: $app is missing after the build." >&2
        exit 1
    fi
    just _verify-security-path "$app"
    osascript -e 'quit app "Voice"' >/dev/null 2>&1 || true
    # Wait for the process to exit so files are not replaced under it.
    for _ in $(seq 1 20); do
        pgrep -q -f "/Applications/Voice.app/Contents/MacOS/Voice" || break
        sleep 0.5
    done
    ditto "$app" /Applications/Voice.app
    codesign --verify --deep --strict /Applications/Voice.app
    open -a /Applications/Voice.app
    echo "installed and relaunched /Applications/Voice.app"

# The app is not sandboxed: it drives other apps through Accessibility, posts
# keyboard events, and launches planning-agent processes, none of which a
# sandboxed process can do. The audit below proves everything else the build
# claims: Hardened Runtime, an arm64e (pointer-authenticated) slice, Enhanced
# Security v2, and the hard-mode Memory Integrity Enforcement entitlements.
#
# Audit the signed Release app for Hardened Runtime, arm64e, and Enhanced Security.
verify-security: release-signed
    @just _verify-security-path "{{release_derived_data}}/Build/Products/Release/Voice.app"

[private]
_verify-security-path app:
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{app}}"
    audit_dir="$(mktemp -d -t voice-security)"
    entitlements="${audit_dir}/entitlements.plist"
    signature="${audit_dir}/signature.txt"
    trap 'rm -f "${entitlements}" "${signature}"; rmdir "${audit_dir}" 2>/dev/null || true' EXIT

    codesign --verify --deep --strict "${app}"

    require_entitlement() {
        local key="$1" expected="$2" actual
        actual="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${entitlements}" 2>/dev/null || true)"
        if [[ "${actual}" != "${expected}" ]]; then
            printf 'Security verification failed: %s is not %s.\n' "${key}" "${expected}" >&2
            exit 1
        fi
    }
    reject_entitlement() {
        local key="$1"
        if /usr/libexec/PlistBuddy -c "Print :${key}" "${entitlements}" >/dev/null 2>&1; then
            printf 'Security verification failed: forbidden entitlement %s is present.\n' "${key}" >&2
            exit 1
        fi
    }

    audit_executable() {
        local signed="$1" executable="$2"
        codesign --display --entitlements - --xml "${signed}" >"${entitlements}" 2>/dev/null
        codesign --display --verbose=2 "${signed}" >"${signature}" 2>&1
        require_entitlement com.apple.security.hardened-process true
    require_entitlement com.apple.security.hardened-process.checked-allocations true
    require_entitlement com.apple.security.hardened-process.checked-allocations.enable-pure-data true
    require_entitlement com.apple.security.hardened-process.enhanced-security-version-string 2
    require_entitlement com.apple.security.hardened-process.hardened-heap true
    require_entitlement com.apple.security.hardened-process.dyld-ro true
    require_entitlement com.apple.security.hardened-process.platform-restrictions-string 2

    reject_entitlement com.apple.security.hardened-process.checked-allocations.soft-mode
    reject_entitlement com.apple.security.cs.allow-jit
    reject_entitlement com.apple.security.cs.allow-unsigned-executable-memory
    reject_entitlement com.apple.security.cs.disable-executable-page-protection
    reject_entitlement com.apple.security.cs.disable-library-validation
    reject_entitlement com.apple.security.cs.allow-dyld-environment-variables
    reject_entitlement com.apple.security.get-task-allow
        if ! grep -q 'flags=.*runtime' "${signature}"; then
            printf 'Security verification failed: %s lacks Hardened Runtime.\n' "${executable}" >&2
            exit 1
        fi
        if [[ " $(lipo -archs "${executable}") " != *' arm64e '* ]]; then
            printf 'Security verification failed: %s has no arm64e slice.\n' "${executable}" >&2
            exit 1
        fi
    }

    audit_executable "${app}" "${app}/Contents/MacOS/{{scheme}}"
    require_entitlement com.apple.security.device.audio-input true
    audit_executable "${app}/Contents/MacOS/voice-say" "${app}/Contents/MacOS/voice-say"

    printf 'Verified Hardened Runtime, arm64e, Enhanced Security v2, and hard-mode MIE entitlements.\n'

# Build a short-lived ad-hoc Release app without an Apple certificate.
release-adhoc: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{release_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER= build

# Unsigned build + test for CI runners, which have no signing identity.
# Safe there because every run starts with fresh DerivedData; locally,
# mixing signed and unsigned parameters in one DerivedData breaks Xcode's
# explicit-module scanner (see Configs/Project.xcconfig).
ci: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build test

setup-lsp: generate
    xcode-build-server config -project {{project}} -scheme {{scheme}}

# Build the voice-say CLI and print its path, so agents and scripts can speak
# through the local Qwen3-TTS voices instead of the system synthesizer.

say-cli: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme VoiceSay -configuration Release -destination '{{destination}}' -derivedDataPath {{cli_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build
    @echo "{{cli_derived_data}}/Build/Products/Release/voice-say"

# Install voice-say onto PATH. Defaults to ~/.local/bin, which needs no sudo;
# pass another directory to override, e.g. `just install /usr/local/bin`.
#
# MLX loads its Metal shaders from a resource bundle resolved next to the
# running executable, so the binary cannot be copied on its own. The payload
# (binary plus bundles) goes to <prefix>/../libexec/voice-say and a small exec
# wrapper goes on PATH. A symlink does not work: the bundle is then looked up
# beside the link rather than beside the real binary.
#
# Building is not a dependency of this recipe because a system-wide install
# needs sudo: running the build as root would leave root-owned artifacts in
# Voice.xcodeproj and .build, breaking the next ordinary build. The build is
# instead run as the invoking user below.
install prefix="~/.local/bin":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        sudo -u "$SUDO_USER" just say-cli
    else
        just say-cli
    fi
    products="{{cli_derived_data}}/Build/Products/Release"
    # Under sudo HOME is root's, so expand ~ against the invoking user instead
    # of installing into /var/root.
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        home_dir="$(eval echo "~$SUDO_USER")"
    else
        home_dir="$HOME"
    fi
    prefix_raw="{{prefix}}"
    bindir="${prefix_raw/#\~/$home_dir}"
    libexec="$(dirname "$bindir")/libexec/voice-say"

    if [[ ! -x "$products/voice-say" ]]; then
        echo "error: $products/voice-say is missing; run 'just say-cli' first." >&2
        exit 1
    fi
    for dir in "$bindir" "$libexec"; do
        if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
            echo "error: $dir is not writable." >&2
            echo "Re-run with sudo, or install somewhere you own: just install ~/.local/bin" >&2
            exit 1
        fi
    done

    install -m 755 "$products/voice-say" "$libexec/voice-say"
    rsync -a --delete-excluded --include='*/' --include='*' \
        "$products"/*.bundle "$libexec/" 2>/dev/null \
        || cp -R "$products"/*.bundle "$libexec/"
    printf '#!/bin/sh\nexec "%s/voice-say" "$@"\n' "$libexec" > "$bindir/voice-say"
    chmod 755 "$bindir/voice-say"

    codesign --verify "$libexec/voice-say" 2>/dev/null \
        || echo "warning: signature did not survive the copy" >&2
    echo "installed $bindir/voice-say -> $libexec/voice-say"
    if ! command -v voice-say >/dev/null 2>&1; then
        echo "note: $bindir is not on PATH; add it to use 'voice-say' directly." >&2
    fi

# Measure downloaded MLX dictation models against the local clip corpus.
# Record clips into Bench/corpus/ as <name>.wav + <name>.txt reference pairs.
bench corpus="Bench/corpus": generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme VoiceBench -configuration Debug -destination '{{destination}}' -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build
    {{debug_derived_data}}/Build/Products/Debug/VoiceBench {{corpus}}

fmt:
    xcrun swift-format format --in-place --recursive Sources Tests Packages/VoiceMLXRuntime

lint:
    xcrun swift-format lint --recursive --strict Sources Tests Packages/VoiceMLXRuntime

clean:
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile clean
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath {{release_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile clean
