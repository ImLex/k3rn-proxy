# K3RN Intel — iOS

Native SwiftUI client for the K3RN Intel Supabase backend (same DB as the web
dashboard, Discord bot, and the capture proxy). Built on Windows-authored source;
the `.ipa` is produced by macOS CI (GitHub Actions).

## Local project generation (on a Mac)

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill in the anon key
xcodegen generate
open K3RNIntel.xcodeproj
```

`Config/Secrets.xcconfig` is gitignored. `SUPABASE_HOST` is the host only (no
`https://`) because xcconfig treats `//` as a comment — the app prepends the
scheme. The anon key is safe on a client; RLS is the security boundary.

## CI → .ipa (GitHub Actions)

Workflow: `.github/workflows/ios.yml`. Every push/PR runs a simulator compile
check (no signing). A signed `.ipa` is archived + exported **only when the App
Store Connect signing secrets are set**.

Push this `ios/` folder as its own repository root (the workflow lives at
`.github/workflows/ios.yml`).

### Required GitHub secrets (for the signed .ipa)

| Secret | What |
| --- | --- |
| `SUPABASE_ANON_KEY` | Supabase anon/publishable key |
| `APPLE_TEAM_ID` | Apple Developer Team ID (10 chars) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_KEY_P8_BASE64` | The `AuthKey_XXXX.p8`, base64-encoded (`base64 -i AuthKey.p8`) |

Optional repo **Variables** (override the defaults baked into the workflow):
`SUPABASE_HOST`, `DISCORD_GUILD_ID`, `DISCORD_OFFICER_ROLE_ID`,
`DISCORD_K3RN_ROLE_ID`.

The API key needs the **App Manager** role (create it in App Store Connect →
Users and Access → Integrations → App Store Connect API). Signing uses
`-allowProvisioningUpdates`, so Xcode manages the certificate/profile.

`ExportOptions.plist` `method` is `app-store` (TestFlight). Change to `ad-hoc`
for direct device installs (registered UDIDs) or `development` for dev signing.

### One-time Apple setup you must do

1. Apple Developer Program membership (paid).
2. Register the app's bundle id `site.k3rn.intel` in App Store Connect.
3. Add `k3rnintel://auth-callback` to Supabase Auth → URL Configuration →
   Redirect URLs.
