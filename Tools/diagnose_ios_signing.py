#!/usr/bin/env python3
"""Read-only diagnostics for an iOS app rejected with 0xe8008015.

Usage:
    python3 Tools/diagnose_ios_signing.py /path/to/App.app

Prints public certificate fingerprints and entitlement key comparisons only.
Does not modify provisioning profiles, certificates, Keychain, or the device.
"""
import hashlib
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 Tools/diagnose_ios_signing.py /path/to/App.app")
        return 2
    app = Path(sys.argv[1]).expanduser()
    profile_path = app / "embedded.mobileprovision"
    if not (app / "Info.plist").is_file() or not profile_path.is_file():
        print("ERROR: App bundle or embedded.mobileprovision missing.")
        return 2

    profile = plistlib.loads(command("security", "cms", "-D", "-i", str(profile_path)))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    signing = plistlib.loads(command("codesign", "-d", "--entitlements", "-", str(app)))
    allowed = profile.get("Entitlements", {})

    print("=== APP / PROFILE ===")
    print("Bundle ID:", info.get("CFBundleIdentifier"))
    print("Profile:", profile.get("Name"))
    print("Profile UUID:", profile.get("UUID"))
    print("Profile expiry:", profile.get("ExpirationDate"))
    print("Team:", profile.get("TeamIdentifier"))
    print("Registered device count:", len(profile.get("ProvisionedDevices", [])))

    print("\n=== DEVELOPMENT CERTIFICATES IN PROFILE (SHA-1) ===")
    for certificate in profile.get("DeveloperCertificates", []):
        print(hashlib.sha1(certificate).hexdigest().upper())

    print("\n=== LOCAL SIGNING IDENTITIES ===")
    identities = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        text=True, capture_output=True, check=False,
    )
    for line in identities.stdout.splitlines():
        if "Apple Development:" in line:
            print(line.strip())

    print("\n=== SIGNED ENTITLEMENTS VS PROFILE ===")
    mismatches = []
    for key, value in sorted(signing.items()):
        approved = allowed.get(key)
        if approved == value or approved == "*":
            state = "MATCH"
        elif isinstance(approved, list) and isinstance(value, list) and set(value).issubset(set(approved)):
            state = "MATCH"
        elif key not in allowed:
            state = "NOT IN PROFILE"
            mismatches.append(key)
        else:
            state = "DIFFERENT"
            mismatches.append(key)
        print(f"{state}: {key}")

    print("\n=== RESULT ===")
    if mismatches:
        print("Investigate these entitlements:", ", ".join(mismatches))
        return 1
    print("No obvious entitlement mismatch; investigate certificate/profile trust and nested bundles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
