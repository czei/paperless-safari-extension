---
title: Privacy Policy — Paperless Clipper
---

# Privacy Policy

**Last updated:** 2026-04-27

Paperless Clipper is a Safari Web Extension that saves the page you're
currently viewing to a Paperless-ngx server **that you operate**. This
document describes the data the extension touches and where it goes.

## What the extension reads

When you press the save action, the extension reads:

- The active tab's URL and `<title>`
- The article-extracted text and structure of the active page (via
  Mozilla Readability, running locally in your browser)
- The server URL and API token you entered in Settings

It does **not** read other tabs, browsing history, cookies, form data,
or any data outside the page you explicitly chose to save.

## Where the data goes

The captured page is rendered locally to a PDF on your device using
Apple's `WKWebView`, then uploaded over HTTPS to **the Paperless-ngx
server you configured in Settings**. That's the only network
destination involved in a save.

The extension does **not**:

- Send any data to the developer or Web Performance Incorporated
- Use any third-party analytics, telemetry, crash reporting, or
  advertising service
- Use any third-party rendering, OCR, or content-conversion service
- Phone home for updates, configuration, or feature flags

## What is stored on your device

- **Server URL**: stored in the extension's `browser.storage.local`
- **API token**: stored in the platform Keychain (macOS / iOS), shared
  between the containing app and the extension via an App Group
- **Recent save state**: a short list of recent successes/failures,
  stored in App Group `UserDefaults`, used only to populate the popup
  status

You can clear all of this by uninstalling Paperless Clipper from
Safari (and, on macOS, deleting the containing app from
`/Applications`).

## Data sent to your Paperless server

When you save a page, the following is uploaded to your configured
Paperless-ngx server, over HTTPS:

- A PDF of the captured page
- The page title
- The page's source URL (preserved in the document title and/or a
  custom field, depending on your server configuration)

What your Paperless server then does with that document — OCR,
classification, storage — is governed by your server, not by this
extension.

## Source code

The extension is open-source. You can audit the code, the build
script, and every network call yourself at:

[github.com/czei/paperless-safari-extension](https://github.com/czei/paperless-safari-extension)

## Contact

Issues and questions: please open a GitHub issue at the URL above.
