# Paperless Clipper

A Safari Web Extension for macOS and iOS/iPadOS that one-tap-saves the active webpage to a self-hosted [Paperless-ngx](https://docs.paperless-ngx.com/) server.

The user shares the page; classification (tags, correspondent, document type, refined title) happens server-side via Paperless's existing AI/classifier pipeline. There is no metadata UI on the save path.

## Status

Early development. **Phase 1 (Setup) and Phase 2 (Foundational) scaffolding are in place.** Phase 3 (validation prototypes) is the next step and requires real iOS hardware + access to a running Paperless server.

## Where things live

- **Spec, plan, tasks, research, contracts**: in the sibling repository at [`../paperless-ngx/specs/001-safari-web-clipper/`](../paperless-ngx/specs/001-safari-web-clipper/).
- **TypeScript Web Extension code**: `web/src/`
- **Swift containing-app code**: `apps/macOS/`, `apps/iOS/`
- **Swift code shared across targets**: `shared-swift/`
- **Native bridge** (lives in the extension target): `extension/SafariWebExtensionHandler.swift`
- **Build helper script**: `scripts/build-web.sh`

## Getting started

See [`SETUP.md`](./SETUP.md) for the one-time Xcode project creation, App Group / URL scheme / Background URLSession configuration, and the build-script wiring.

## License

TBD.
