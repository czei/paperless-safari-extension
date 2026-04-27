# Paperless Clipper

A Safari Web Extension for macOS and iOS/iPadOS that one-tap-saves the active webpage to a self-hosted [Paperless-ngx](https://docs.paperless-ngx.com/) server.

You share the page; classification (tags, correspondent, document type, refined title) happens server-side via Paperless's existing AI/classifier pipeline. There is no metadata UI on the save path.

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/popup-save.png" alt="Save view: one big Save current page button" />
      <br/><sub>Default view: one tap to save</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/popup-settings.png" alt="Settings view: server URL and API token" />
      <br/><sub>Settings: server URL + API token</sub>
    </td>
  </tr>
</table>

## Install (macOS)

1. Download the latest `.dmg` from [Releases](https://github.com/czei/paperless-safari-extension/releases).
2. Open the DMG and drag **Paperless Clipper** to **Applications**.
3. Launch the app once (Spotlight: "Paperless Clipper") so macOS registers the bundled extension.
4. Open **Safari → Settings → Extensions** and enable **Paperless Clipper**.
5. Get your Paperless API token: log in to your Paperless server in a browser, click the **account dropdown** in the top-right, choose **My Profile**, and copy the **API Auth Token**.
6. Click the leaf icon in the Safari toolbar → **gear** → enter your Paperless server URL and paste the token.
7. Click the leaf again on any page and tap **Save current page**.

The DMG is signed by Web Performance Incorporated and notarized by Apple, so no Gatekeeper warnings.

## How it works

1. **Capture**: A content script runs [Mozilla Readability](https://github.com/mozilla/readability) on a clone of the active document, producing a clean reader-mode HTML article.
2. **Render**: The HTML is rendered locally to a paginated PDF via `WKWebView.createPDF` in the extension process.
3. **Upload**: The PDF is POSTed over HTTPS to your Paperless server's `/api/documents/post_document/` endpoint with the page's source URL preserved in the title.

The whole pipeline runs on your device. The PDF and your API token never leave your network except to reach the Paperless server you configured.

## Privacy

No telemetry, no third-party services, no phoning home. See [PRIVACY.md](./PRIVACY.md).

## Status

- **macOS**: working end-to-end. Released as a notarized DMG (Developer ID, signed by Web Performance Incorporated).
- **iOS / iPadOS**: working in the iPhone simulator with the same in-extension architecture as macOS. Real-device validation pending; no public iOS release yet.

## Repository layout

- **TypeScript Web Extension code**: `web/src/`
- **Swift containing-app code**: `apps/macOS/`, `apps/iOS/`
- **Swift code shared across targets**: `shared-swift/`
- **Native bridge** (lives in the extension target): `extension/SafariWebExtensionHandler.swift`
- **Build helper scripts**: `scripts/build-web.sh`, `scripts/release-macos.sh`
- **Spec, plan, tasks, research, contracts**: live in the sibling repository under `paperless-ngx/specs/001-safari-web-clipper/`

## Building from source

See [`SETUP.md`](./SETUP.md) for the one-time Xcode project setup, signing, and build configuration.

To produce a notarized release DMG, see the prerequisites at the top of `scripts/release-macos.sh`, then:

```sh
bash scripts/release-macos.sh
```

The output lands at `build/release/PaperlessClipper-<version>.dmg`.

## License

TBD.
