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

The app's **Check release identity** build phase runs `scripts/check-release-identity.sh`. It is skipped only for a plain Debug build. Every other build fails if the team is missing, malformed or upstream's, the bundle ID is a known placeholder or in upstream's namespace, or the effective app ID or team differs from the organisation settings. That covers Release, any custom configuration, and any archive (including an archive of Debug). `scripts/test-check-release-identity.sh` exercises the guard and runs in CI.

Xcode's Profile action builds Release, so it fails locally until `ORG_TEAM_ID` and `ORG_BUNDLE_ID` are set.

The guard validates configuration, not ownership of an Apple team or identifier. Keep the phase enabled in packaging, and have the pipeline check the archived app's `CFBundleIdentifier` and signing team (`codesign -dv`) before notarization and distribution.

Managed preferences are keyed by bundle ID: an MDM custom-settings payload must use the production `ORG_BUNDLE_ID` as its `PayloadType` (preference domain). Profiles written for `org.p0deje.Maccy` do not apply.

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

The About panel has one link, to the fork repository. Upstream's credits remain as text without links. Upstream copyright and the MIT licence remain intact.
