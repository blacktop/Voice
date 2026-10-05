project := "Voice.xcodeproj"
scheme := "Voice"
# Xcode's explicit-module cache is configuration-sensitive for the MLX/NIO C
# shims, so Debug and Release must not share DerivedData.
debug_derived_data := ".build/DerivedData-Debug"
release_derived_data := ".build/DerivedData-Release"
# The CLI tools are separate schemes; building them into the app's DerivedData
# changes the build parameters enough to break the explicit-module scan.
cli_derived_data := ".build/DerivedData-CLI"
notify_derived_data := ".build/DerivedData-Notify"
adhoc_app_entitlements := ".build/VoiceAdhoc.entitlements"
source_packages := ".build/SourcePackages"
destination := "platform=macOS,arch=arm64e"

default: build

generate:
    xcodegen generate

build: generate
    @just _local-build Debug build

test: test-build-scripts
    @just _local-build Debug test

# Check generated capability metadata and the installation signing audit.
test-build-scripts: generate
    /usr/bin/python3 -m unittest discover -s Tests/BuildScriptsTests

release: generate
    @just _local-build Release build

# Local compile/test builds can use ad-hoc signing when no team is configured.
# Signed install and distribution recipes do not use this fallback.
[private]
_local-build configuration action:
    #!/usr/bin/env bash
    set -euo pipefail
    configuration={{quote(configuration)}}
    action={{quote(action)}}
    case "$configuration" in
        Debug) derived_data="{{debug_derived_data}}" ;;
        Release) derived_data="{{release_derived_data}}" ;;
        *) echo "error: unsupported build configuration: $configuration" >&2; exit 64 ;;
    esac
    case "$action" in build|test) ;; *) echo "error: unsupported build action: $action" >&2; exit 64 ;; esac
    build=(
        ./scripts/xcbuild.sh -quiet
        -project "{{project}}"
        -scheme "{{scheme}}"
        -configuration "$configuration"
        -destination "{{destination}}"
        -derivedDataPath "$derived_data"
        -clonedSourcePackagesDirPath "{{source_packages}}"
        -onlyUsePackageVersionsFromResolvedFile
        ARCHS=arm64e
        ONLY_ACTIVE_ARCH=YES
    )
    signing_mode=adhoc
    if security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eq '^[[:space:]]*[1-9][0-9]* valid identities found$'; then
        settings_file="$(mktemp -t voice-build-settings)"
        trap 'rm -f "$settings_file"' EXIT
        "${build[@]}" -showBuildSettings -json >"$settings_file"
        signing_mode="$(/usr/bin/python3 - "$settings_file" <<'PY'
    import json
    import sys
    with open(sys.argv[1]) as source:
        entries = json.load(source)
    target = next((entry for entry in entries if entry.get("target") == "Voice"), None)
    if target is None:
        sys.exit("Voice build settings are unavailable")
    print("signed" if target["buildSettings"].get("DEVELOPMENT_TEAM", "").strip() else "adhoc")
    PY
        )"
    fi
    if [[ "$signing_mode" == signed ]]; then
        echo "Building a signed $configuration app with the configured team."
        "${build[@]}" "$action"
    else
        echo "Warning: no configured signing team or identity; using an ad-hoc $configuration app." >&2
        echo "Use 'just release-signed' when permission identity or Keychain behavior matters." >&2
        just _adhoc-app-entitlements
        "${build[@]}" \
            CODE_SIGN_STYLE=Manual \
            DEVELOPMENT_TEAM= \
            CODE_SIGN_IDENTITY=- \
            PROVISIONING_PROFILE_SPECIFIER= \
            VOICE_APP_ENTITLEMENTS={{adhoc_app_entitlements}} \
            "$action"
    fi

release-signed: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{release_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build

# Install the signed app and both CLIs. The prefix applies to the CLI wrappers.
install prefix="~/.local/bin":
    #!/usr/bin/env bash
    set -euo pipefail
    # Keep the app build and relaunch in the invoking user's GUI session.
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        sudo -u "$SUDO_USER" just install-app
    else
        just install-app
    fi
    just install-cli {{quote(prefix)}}
    just install-notify {{quote(prefix)}}

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
    /usr/bin/python3 scripts/verify-provisioning.py "${app}" "${entitlements}" "${signature}"
    audit_executable "${app}/Contents/MacOS/voice-say" "${app}/Contents/MacOS/voice-say"
    reject_entitlement keychain-access-groups
    audit_executable "${app}/Contents/MacOS/voice-notify" "${app}/Contents/MacOS/voice-notify"
    reject_entitlement keychain-access-groups

    printf 'Verified Hardened Runtime, arm64e, Enhanced Security v2, hard-mode MIE, and provisioning authorization.\n'

# Build a short-lived ad-hoc Release app without an Apple certificate.
release-adhoc: generate _adhoc-app-entitlements
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{release_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER= VOICE_APP_ENTITLEMENTS={{adhoc_app_entitlements}} build

# Keep compile-only ad-hoc builds free of entitlements that require a profile.
[private]
_adhoc-app-entitlements:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .build
    cp Configs/Voice.entitlements {{adhoc_app_entitlements}}
    for key in com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups; do
        /usr/libexec/PlistBuddy -c "Delete :$key" {{adhoc_app_entitlements}}
    done

# Unsigned build + test for CI runners, which have no signing identity.
# Safe there because every run starts with fresh DerivedData; locally,
# mixing signed and unsigned parameters in one DerivedData breaks Xcode's
# explicit-module scanner (see Configs/Project.xcconfig).
ci: test-build-scripts
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{debug_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build test

setup-lsp: generate
    xcode-build-server config -project {{project}} -scheme {{scheme}}

# Build the voice-say CLI and print its path, so agents and scripts can speak
# through the local Qwen3-TTS voices instead of the system synthesizer.

say-cli: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme VoiceSay -configuration Release -destination '{{destination}}' -derivedDataPath {{cli_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build
    @echo "{{cli_derived_data}}/Build/Products/Release/voice-say"

notify-cli: generate
    ./scripts/xcbuild.sh -quiet -project {{project}} -scheme VoiceNotify -configuration Release -destination '{{destination}}' -derivedDataPath {{notify_derived_data}} -clonedSourcePackagesDirPath {{source_packages}} -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build
    @echo "{{notify_derived_data}}/Build/Products/Release/voice-notify"

# Keep the executable's signed payload separate from the PATH wrapper, as for
# voice-say. The tool itself has no MLX resource bundles.
install-notify prefix="~/.local/bin":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        sudo -u "$SUDO_USER" just notify-cli
    else
        just notify-cli
    fi
    just _install-notify-products "{{notify_derived_data}}/Build/Products/Release" {{quote(prefix)}}

[private]
_install-notify-products products prefix:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        home_dir="$(eval echo "~$SUDO_USER")"
    else
        home_dir="$HOME"
    fi
    products={{quote(products)}}
    prefix_raw={{quote(prefix)}}
    bindir="${prefix_raw/#\~/$home_dir}"
    mkdir -p "$bindir"
    bindir="$(cd "$bindir" && pwd -P)"
    libexec="$(dirname "$bindir")/libexec/voice-notify"
    mkdir -p "$libexec"
    install -m 755 "$products/voice-notify" "$libexec/voice-notify"
    # Quote the resolved executable for /bin/sh, including spaces and apostrophes.
    apostrophe="'\"'\"'"
    quoted="${libexec//\'/$apostrophe}"
    printf '#!/bin/sh\nexec '\''%s/voice-notify'\'' "$@"\n' "$quoted" > "$bindir/voice-notify"
    chmod 755 "$bindir/voice-notify"
    codesign --verify "$libexec/voice-notify"
    echo "installed $bindir/voice-notify -> $libexec/voice-notify"

# Install voice-say onto PATH. Defaults to ~/.local/bin, which needs no sudo;
# pass another directory to override, e.g. `just install-cli /usr/local/bin`.
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
install-cli prefix="~/.local/bin":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        sudo -u "$SUDO_USER" just say-cli
    else
        just say-cli
    fi
    just _install-cli-products "{{cli_derived_data}}/Build/Products/Release" {{quote(prefix)}}

[private]
_install-cli-products products prefix:
    #!/usr/bin/env bash
    set -euo pipefail
    products={{quote(products)}}
    # Under sudo HOME is root's, so expand ~ against the invoking user instead
    # of installing into /var/root.
    if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} ]]; then
        home_dir="$(eval echo "~$SUDO_USER")"
    else
        home_dir="$HOME"
    fi
    prefix_raw={{quote(prefix)}}
    bindir="${prefix_raw/#\~/$home_dir}"
    libexec="$(dirname "$bindir")/libexec/voice-say"

    if [[ ! -x "$products/voice-say" ]]; then
        echo "error: $products/voice-say is missing; run 'just say-cli' first." >&2
        exit 1
    fi
    for dir in "$bindir" "$libexec"; do
        if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
            echo "error: $dir is not writable." >&2
            echo "Re-run with sudo, or install somewhere you own: just install-cli ~/.local/bin" >&2
            exit 1
        fi
    done
    bindir="$(cd "$bindir" && pwd -P)"
    libexec="$(cd "$libexec" && pwd -P)"

    install -m 755 "$products/voice-say" "$libexec/voice-say"
    rsync -a --delete-excluded --include='*/' --include='*' \
        "$products"/*.bundle "$libexec/" 2>/dev/null \
        || cp -R "$products"/*.bundle "$libexec/"
    apostrophe="'\"'\"'"
    quoted="${libexec//\'/$apostrophe}"
    printf '#!/bin/sh\nexec '\''%s/voice-say'\'' "$@"\n' "$quoted" > "$bindir/voice-say"
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
