# Stable local signing

macOS privacy permissions identify signed code using its designated requirement. An ad-hoc signature identifies a particular build; a normal certificate signature can identify successive builds. Keep WindowHop's bundle identifier (`dog.malloc.windowhop`), signing channel, and certificate identity stable. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## Configure once

The certificate and its matching private key must be in Keychain. A downloaded `.cer` alone does not contain the private key. An Apple Development identity works for local builds; Developer ID Application is intended for direct distribution. Switching between these identities changes the default designated requirement.

List valid identities:

```sh
security find-identity -v -p codesigning
```

Copy the selected identity's 40-character fingerprint into `.signing-identity` at the repository root, as one line. This local file is ignored by Git. It contains an identity reference, never a certificate or private key. Then build normally:

```sh
./scripts/build.sh
```

An explicit `SIGN_IDENTITY` environment variable overrides the local file. If neither is configured, builds use an ad-hoc signature. If the configured certificate cannot sign, the build fails without replacing the previous working app or silently switching identities. Keychain may ask permission for `codesign` to use the private key.

Builds hold a local directory lock to prevent two invocations from replacing the app at once. Normal exits release it. If a build is forcibly killed and leaves `dist/.windowhop-build.lock`, confirm no build is running before removing that empty directory.

Quit the running app and relaunch the new bundle after changing its signature. Moving from ad-hoc signing to a certificate may require one final Accessibility approval. Later builds should retain authorization when their identity stays consistent; verify this through a real rebuild and launch rather than assuming it from signature verification alone.

## Inspect and verify

```sh
codesign --verify --strict dist/WindowHop.app
codesign -d -r- --verbose=2 dist/WindowHop.app
```

The output should identify the certificate authority and team and contain a certificate-based designated requirement, rather than only `cdhash`. A requirement captured from one signed build can be passed to `codesign --verify -R` to check identity continuity after another build.

If an identity appears under `security find-identity -p codesigning` but not under its `-v` valid-only output, inspect certificate validity and its chain. Use Apple's standard intermediate certificates when needed; do not work around verification failure by marking the leaf certificate Always Trust. [Apple certificate authority](https://www.apple.com/certificateauthority/)

Notarization, hardened runtime, and Developer ID distribution are separate from preserving local Accessibility authorization. [Apple distribution-signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
