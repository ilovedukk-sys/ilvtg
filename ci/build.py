#!/usr/bin/env python3
"""Build an unsigned ilvtg IPA from a tree prepared by ci/prepare.py (macOS runner only).

The IPA carries no provisioning profile: install it with a re-signing tool (Sideloadly,
AltStore, SideStore, a developer certificate) or TrollStore.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def die(message: str):
    raise SystemExit("[ilvtg] " + message)


def patch_rules_apple(source: Path):
    """Device builds normally require a provisioning profile; skip that partial when the
    ilvtg_unsigned feature is on (set in .bazelrc by prepare.py)."""
    path = source / "build-system/bazel-rules/rules_apple/apple/internal/ios_rules.bzl"
    if not path.is_file():
        die(f"{path} not found: fetch submodules first")
    with open(path, encoding="utf-8", newline="") as handle:
        text = handle.read()
    if "ilvtg_unsigned" in text:
        return
    old = "    if platform_prerequisites.platform.is_device:\n        processor_partials.append(\n            partials.provisioning_profile_partial("
    new = "    if platform_prerequisites.platform.is_device and \"ilvtg_unsigned\" not in features:\n        processor_partials.append(\n            partials.provisioning_profile_partial("
    found = text.count(old)
    if found == 0:
        die("rules_apple layout changed: provisioning_profile_partial anchor not found")
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text.replace(old, new))
    print(f"[ilvtg] rules_apple: unsigned device builds enabled in {found} rule(s)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--configuration", default="release_arm64", choices=["release_arm64", "debug_arm64"])
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()

    if sys.platform != "darwin":
        die("the native build needs macOS")
    if not (source / ".ilvtg-applied").exists():
        die("run ci/prepare.py first")

    versions = json.loads((source / "versions.json").read_text())
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()[0].split()[1]
    if xcode != versions["xcode"]:
        die(f"Telegram-iOS at this commit needs Xcode {versions['xcode']}, the runner has {xcode}")

    patch_rules_apple(source)

    app = json.loads((ROOT / "app.json").read_text(encoding="utf-8"))
    api_id = os.environ.get("TELEGRAM_API_ID", "").strip()
    api_hash = os.environ.get("TELEGRAM_API_HASH", "").strip()
    has_credentials = bool(api_id or api_hash)
    if has_credentials:
        if not api_id.isdigit() or not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
            die("TELEGRAM_API_ID must be a number and TELEGRAM_API_HASH 32 hex characters")
    else:
        api_id, api_hash = "0", ""
        print("::warning::TELEGRAM_API_ID / TELEGRAM_API_HASH secrets are not set: this IPA compiles but cannot log in")

    configuration = json.loads((source / "build-system/template_minimal_development_configuration.json").read_text())
    configuration.update(
        bundle_id=app["bundle_id"],
        api_id=api_id,
        api_hash=api_hash,
        team_id="ILVTGBUILD",
        app_center_id="0",  # AppCenter is not linked into the app; "0" only satisfies the template
        is_internal_build="false",
        is_appstore_build="false",
        appstore_id="0",
        app_specific_url_scheme=app["url_scheme"],
        premium_iap_product_id="",
        enable_siri=False,
        enable_icloud=False,
    )
    temp = Path(os.environ.get("RUNNER_TEMP", "/tmp"))
    config_path = temp / "ilvtg-configuration.json"
    config_path.write_text(json.dumps(configuration))
    config_path.chmod(0o600)

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable, "build-system/Make/Make.py",
        "--cacheDir=" + str(args.cache_dir.resolve()),
        "build",
        "--configurationPath=" + str(config_path),
        "--xcodeManagedCodesigning",
        "--buildNumber=" + os.environ.get("GITHUB_RUN_NUMBER", "1"),
        "--configuration=" + args.configuration,
        "--outputBuildArtifactsPath=" + str(out),
    ]
    print("[ilvtg] " + " ".join(command))
    try:
        result = subprocess.run(command, cwd=source)
    finally:
        config_path.unlink(missing_ok=True)
    if result.returncode != 0:
        die(f"Make.py failed with exit code {result.returncode}")

    built = out / "Telegram.ipa"
    if not built.is_file():
        die("the build finished without Telegram.ipa")
    ipa = out / (app["display_name"] + ".ipa")
    built.replace(ipa)
    (out / "Telegram.DSYMs.zip").unlink(missing_ok=True)

    with zipfile.ZipFile(ipa) as archive:
        app_dir = next(n.split("/")[1] for n in archive.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
        info = plistlib.loads(archive.read(f"Payload/{app_dir}/Info.plist"))
        binary = archive.read(f"Payload/{app_dir}/" + info["CFBundleExecutable"])
        if binary[:4] != b"\xcf\xfa\xed\xfe" or int.from_bytes(binary[4:8], "little") != 0x0100000C:
            die("the main executable is not arm64")
        extensions = sorted({n.split("/")[3] for n in archive.namelist() if n.startswith(f"Payload/{app_dir}/PlugIns/") and n.count("/") >= 4})

    manifest = {
        "app": app["display_name"],
        "bundle_id": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "upstream_commit": json.loads((ROOT / "upstream.json").read_text())["commit"],
        "configuration": args.configuration,
        "xcode": xcode,
        "extensions": extensions,
        "telegram_api_credentials": has_credentials,
        "signed": False,
        "ipa_bytes": ipa.stat().st_size,
        "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(f"## {app['display_name']} {manifest['version']} ({manifest['build']})\n\n")
            handle.write(f"- IPA: {manifest['ipa_bytes'] / 1024 ** 2:.1f} MiB, unsigned, arm64\n")
            handle.write(f"- Telegram API credentials: {'configured' if has_credentials else '**missing: login will not work**'}\n")
            handle.write(f"- Extensions: {', '.join(extensions) if extensions else 'none'}\n")
            handle.write(f"- SHA-256: `{manifest['sha256']}`\n")


if __name__ == "__main__":
    main()
