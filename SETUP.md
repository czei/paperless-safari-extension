# Setup

This repository's TypeScript and Swift sources are written, but the **Xcode project file** (`PaperlessClipper.xcodeproj`) and the per-target Xcode capability settings are easier to create by clicking through Xcode's UI than to hand-author. Follow these steps once.

The plan and tasks live in the sibling repository at `../paperless-ngx/specs/001-safari-web-clipper/`.

## 1. Create the Xcode project (T002)

1. Open Xcode → **File → New → Project**.
2. Choose **Multiplatform → App**. Click **Next**.
3. Configure:
   - **Product Name**: `PaperlessClipper`
   - **Organization Identifier**: `org.czei`
   - **Bundle Identifier**: `org.czei.PaperlessClipper` (auto-generated)
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Storage**: None
   - **Include Tests**: yes
4. Save it **inside this repo's root** (`paperless-safari-extension/`). Xcode creates `PaperlessClipper.xcodeproj` and a default app target.
5. Delete the default `ContentView.swift` and the boilerplate `*App.swift` Xcode generates — the real ones are already at `apps/macOS/PaperlessClipperApp.swift` and `apps/iOS/PaperlessClipperApp.swift`.
6. **File → Add Files to "PaperlessClipper"** → select the entire `apps/`, `shared-swift/`, and `tests/swift/` directories. Add to the appropriate targets.

### Add the Web Extension target

7. **File → New → Target**.
8. Choose **macOS → Safari Extension** (also covers iOS via shared resources).
9. Configure:
   - **Product Name**: `PaperlessClipperExtension`
   - **Bundle Identifier**: `org.czei.PaperlessClipper.Extension`
   - **Type**: **Safari Web Extension** (not the legacy Safari App Extension).
10. Xcode generates `extension/SafariWebExtensionHandler.swift` and a stub `Resources/`. Replace `SafariWebExtensionHandler.swift` with the version already at `extension/SafariWebExtensionHandler.swift` in this repo. Delete the stub `Resources/manifest.json` Xcode added — `scripts/build-web.sh` generates this.
11. Add the `tests/swift/` files to a unit-test target if you want native tests; or skip until you do.

## 2. Configure App Groups (T006)

For each of the three targets — macOS app, iOS app, Web Extension — in the **Signing & Capabilities** tab:

1. Click **+ Capability**, add **App Groups**.
2. Click the **+** under App Groups and add `group.org.czei.PaperlessClipper`. Use the **same string** on macOS and iOS — Xcode will prepend the team identifier on macOS at sign time.
3. Click **+ Capability** again and add **Keychain Sharing**. Add `group.org.czei.PaperlessClipper` as the access group.

## 3. Configure URL scheme (T007)

The `apps/macOS/Info.plist` and `apps/iOS/Info.plist` already declare the `paperless-clipper` URL scheme. After Xcode generates each app target, point the target's **Info.plist** at the corresponding file in `apps/macOS/` or `apps/iOS/` (Build Settings → "Info.plist File").

## 4. Configure entitlements (T010)

In each target's Build Settings, set the **Code Signing Entitlements** field to the corresponding `.entitlements` file already in this repo:

- macOS app → `apps/macOS/PaperlessClipper.entitlements`
- iOS app → `apps/iOS/PaperlessClipper.entitlements`
- Web Extension → create a similar file at `extension/PaperlessClipperExtension.entitlements` with App Group + Keychain Sharing entries (same identifiers).

## 5. Wire the build script (T005)

On the Web Extension target → **Build Phases**:

1. **+ → New Run Script Phase**.
2. Drag the new phase **above** "Copy Bundle Resources".
3. **Shell**: `/bin/zsh`
4. **Script**: `${SRCROOT}/scripts/build-web.sh`
5. **Input File Lists**: add an entry per `web/src/**/*` and `web/package.json`.
6. **Output Files**: add `${SRCROOT}/extension/Resources/manifest.json` (and any other key bundle outputs).

Without this ordering, you'll get stale JS or invalid signatures.

## 6. Configure Background URLSession (T008)

The constants are already defined in `apps/macOS/PaperlessClientConfig.swift` and `apps/iOS/PaperlessClientConfig.swift`. No Xcode change needed; verify both files compile.

## 7. Build to "empty success" (Setup checkpoint)

- Select the macOS scheme → Build (⌘B). Should succeed with the bare app starting up.
- Select the iOS scheme → Build for an iOS Simulator. Should succeed.
- The extension shows up in Safari → Settings → Extensions but does nothing yet.

You're now ready for **Phase 3** (validation prototypes) per `../paperless-ngx/specs/001-safari-web-clipper/tasks.md`.
