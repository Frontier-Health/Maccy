#!/bin/sh
# Fails any distributable build that still carries the development placeholder
# identity or upstream's identity. Only a plain Debug build (not an archive or
# install) is exempt, so a renamed or copied configuration is still checked.
set -eu
if [ "${CONFIGURATION:-}" = Debug ] && [ "${ACTION:-}" != install ]; then
  exit 0
fi

fail() {
  echo "error: $* Set ORG_TEAM_ID and ORG_BUNDLE_ID in Config/Organisation.xcconfig or override them for packaging." >&2
  exit 1
}

printf '%s\n' "${ORG_TEAM_ID:-}" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$' || fail 'Replace <ORG_TEAM_ID> with a ten-character Apple Developer team ID.'
[ "$ORG_TEAM_ID" != MN3X4648SC ] || fail 'The team ID belongs to upstream.'
printf '%s\n' "${ORG_BUNDLE_ID:-}" | /usr/bin/grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' || fail 'Replace <ORG_BUNDLE_ID> with a reverse-DNS bundle ID.'
case "$(printf '%s' "$ORG_BUNDLE_ID" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
  invalid.*|example.*|com.example.*|org.example.*|org.p0deje.*)
    fail 'The bundle ID is a development placeholder or belongs to upstream.' ;;
esac
[ "${DEVELOPMENT_TEAM:-}" = "$ORG_TEAM_ID" ] || fail 'DEVELOPMENT_TEAM must match ORG_TEAM_ID for distributable builds.'
[ "${PRODUCT_BUNDLE_IDENTIFIER:-}" = "$ORG_BUNDLE_ID" ] || fail 'PRODUCT_BUNDLE_IDENTIFIER must match ORG_BUNDLE_ID for the app.'
