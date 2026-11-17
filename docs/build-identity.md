# Package the organisation build

Staff builds are distributed only through MDM as signed, notarized packages. This fork has no self-updater.

## Set the identity

`Config/Organisation.xcconfig` is the single source of the two operator settings. Both project configurations load it, and all targets inherit it:

- `ORG_TEAM_ID` represents `<ORG_TEAM_ID>`. Its checked-in value is empty for ad-hoc development builds.
- `ORG_BUNDLE_ID` represents `<ORG_BUNDLE_ID>`. Its checked-in value is the buildable development placeholder `invalid.example.Maccy`.

Replace these values for your organisation, or pass them from the separate packaging pipeline:

```sh
xcodebuild archive -project Maccy.xcodeproj -scheme Maccy \
  -configuration Release -archivePath "$ARCHIVE_PATH" \
  ORG_TEAM_ID="$ORG_TEAM_ID" ORG_BUNDLE_ID="$ORG_BUNDLE_ID"
```

Set the two environment variables before this command. Alternatively, pass `-xcconfig "$ORG_IDENTITY_XCCONFIG"` with an externally supplied file defining those same settings. Do not override `PRODUCT_BUNDLE_IDENTIFIER` directly: test bundles and pasteboard declarations must derive from the same app ID. `DEVELOPMENT_TEAM` derives from `ORG_TEAM_ID`.

The app's **Check release identity** build phase runs `scripts/check-release-identity.sh`. Release builds fail if the team is missing or malformed, the bundle ID is a known placeholder or upstream namespace, or the effective app ID or team differs from the organisation settings. This validates configuration, not ownership of an Apple team or identifier. Keep this phase enabled in packaging. Inspect the archived app's `CFBundleIdentifier` and signing team before notarization and distribution.

CI runs Debug unit tests with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`. These overrides do not require Apple credentials and leave the shared identity settings intact.

## Derived identifiers

| Use | Identifier or decision |
| --- | --- |
| App | `$(ORG_BUNDLE_ID)` |
| Unit tests | `$(ORG_BUNDLE_ID).Tests` |
| UI tests | `$(ORG_BUNDLE_ID).UITests`; the test bundle records the app ID in `MaccyAppBundleIdentifier` for accessibility lookup |
| UI-test preferences | App ID plus `.uitests`, isolated from normal preferences |
| Normal preferences | Standard defaults in the app's sandbox and bundle domain |
| Logger and floating panel | Built app bundle ID at runtime |
| OCR dispatch queue | Built app bundle ID plus `.textRecognition` |
| Exported drag type | App ID plus `.pin-reorder`, in both Info.plist and the drag implementation |
| Clipboard origin marker | Built app bundle ID; no upstream marker alias |
| Advanced settings shell commands | Localized templates substitute the built app bundle ID |
| App Intents | Existing Swift intent type names remain; system registration belongs to the containing app bundle |
| Launch at login | Existing LaunchAtLogin-Modern package uses the main app registration; this project has no separate login helper target |
| History | `Maccy/Storage.sqlite` remains relative to Application Support inside the app sandbox, whose container follows the bundle ID |
| App groups | None declared |

`AppIdentity` derives runtime strings from `Bundle.main.bundleIdentifier`, without a second hard-coded app ID. The exported type is private pin reordering data, so no upstream compatibility alias is retained. Third-party clipboard confidentiality markers remain unchanged because they identify other applications' data.

Changing the app ID starts a new preferences domain and sandbox history. No migration from upstream is provided; there are no existing staff installs. Keep the final ID stable after rollout.

All About links point to the fork repository. Upstream copyright and the MIT licence remain intact.
