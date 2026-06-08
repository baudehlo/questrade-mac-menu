# questrade-mac-menu

A Swift + SwiftUI menu-bar-only app for macOS that shows your Questrade account value.

## Features

- Menu bar title displays account value
- Dropdown shows:
  - Account value
  - Daily change
  - Top positions by market value
- Polls Questrade `/accounts/:id/balances` and `/accounts/:id/positions`
- OAuth refresh-token flow with automatic token refresh before expiry and on 401

## Running locally (macOS)

```bash
swift run
```

In the menu dropdown, enter:

- Account ID
- Questrade refresh token

Then click **Start Polling** (or **Reload Now**).

## CI

GitHub Actions workflow is at:

- `.github/workflows/macos-build.yml`

It builds on `macos-latest`, and optionally uses these secrets for signing/notarization:

- `APPLE_CERTIFICATE`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`
