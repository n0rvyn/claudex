---
type: runbook
status: ready
tags: [macos, signing, notarization, release]
---

# ModelBridge Signing and Notarization Runbook

## Current verified machine state

- `security find-identity -v -p codesigning` -> `0 valid identities found`
- `security find-certificate -a -c "Developer ID Application" ~/Library/Keychains/login.keychain-db` -> no output
- `security find-certificate -a -c "Apple Development" ~/Library/Keychains/login.keychain-db` -> no output
- `security find-certificate -a -c "Apple Distribution" ~/Library/Keychains/login.keychain-db` -> no output
- `security find-certificate -a -c "Developer ID Installer" ~/Library/Keychains/login.keychain-db` -> no output
- `security dump-keychain -d ~/Library/Keychains/login.keychain-db | rg 'notarytool|notary|Developer ID Application|Apple Development|Apple Distribution|Developer ID Installer'` -> no output
- `codesign -dv --verbose=4 dist/ModelBridge.app` -> `Signature=adhoc`
- `codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app` -> passes

This machine currently cannot complete a real Developer ID signing or notarization submission.

## What this means

Paying for the Apple Developer Program is not the same thing as having a usable local signing identity.

The current blocker is local machine state:

1. no codesigning identity is installed in the login keychain
2. no notarization-related keychain entry was found in the current login keychain dump
3. the packaged app is only `adhoc` signed, which is sufficient for local packaging but not for Developer ID distribution

## Local packaging vs public distribution

These are two different layers:

1. Local packaged app
   - should use `ad hoc` signing
   - does not require a Developer ID certificate
   - is enough to avoid shipping an entirely unsigned `.app`
2. Public distribution
   - requires `Developer ID Application`
   - requires notarization
   - requires stapling

The packaging script now belongs to layer 1.

## Required prerequisites

1. A valid `Developer ID Application` identity installed in the keychain
2. A configured notary profile for `xcrun notarytool`
3. A fresh app bundle at `dist/ModelBridge.app`

## Signing command

Use:

```bash
MODELBRIDGE_SIGNING_IDENTITY="Developer ID Application: <Team Name> (<TEAMID>)" \
bash scripts/sign_app_bundle.sh
```

Expected result:

- `codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app` passes

## Local ad hoc signing

Current local packaging now runs:

```bash
codesign --force --deep --sign - dist/ModelBridge.app
```

Expected result:

- `codesign -dv --verbose=4 dist/ModelBridge.app` shows `Signature=adhoc`
- `codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app` passes

## Notarization command

Use:

```bash
MODELBRIDGE_NOTARY_PROFILE="<keychain-profile-name>" \
bash scripts/notarize_app_bundle.sh
```

Expected result:

- `xcrun notarytool submit ... --wait` succeeds
- `xcrun stapler staple dist/ModelBridge.app` succeeds

## Verification after notarization

Run:

```bash
spctl --assess --type execute --verbose dist/ModelBridge.app
codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app
```

Expected result:

- Gatekeeper assessment passes
- codesign verification passes

## Delivered now

- [sign_app_bundle.sh](/Users/norvyn/Code/Projects/ModelBridge/scripts/sign_app_bundle.sh)
- [notarize_app_bundle.sh](/Users/norvyn/Code/Projects/ModelBridge/scripts/notarize_app_bundle.sh)

## Not delivered on this machine

- real Developer ID signed app
- real notarization ticket
- stapled final artifact
