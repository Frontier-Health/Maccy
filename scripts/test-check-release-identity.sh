#!/bin/sh
# Exercises check-release-identity.sh with good and bad environments.
set -u
script="$(dirname "$0")/check-release-identity.sh"
failures=0

# expect <pass|fail> <description> VAR=value...
expect() {
  want=$1; name=$2; shift 2
  if env -i PATH=/usr/bin:/bin "$@" /bin/sh "$script" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "FAILED: $name (expected $want, got $got)" >&2
    failures=$((failures + 1))
  fi
}

good="ORG_TEAM_ID=ABCDE12345 DEVELOPMENT_TEAM=ABCDE12345 ORG_BUNDLE_ID=health.frontier.Maccy PRODUCT_BUNDLE_IDENTIFIER=health.frontier.Maccy"
placeholder="ORG_TEAM_ID= DEVELOPMENT_TEAM= ORG_BUNDLE_ID=invalid.example.Maccy PRODUCT_BUNDLE_IDENTIFIER=invalid.example.Maccy"

# shellcheck disable=SC2086
{
expect pass "Debug build with placeholders" CONFIGURATION=Debug ACTION=build $placeholder
expect fail "Debug archive with placeholders" CONFIGURATION=Debug ACTION=install $placeholder
expect fail "Release with placeholders" CONFIGURATION=Release ACTION=build $placeholder
expect fail "Custom configuration with placeholders" CONFIGURATION=Staff ACTION=build $placeholder
expect fail "No configuration set" $placeholder
expect pass "Release with real identity" CONFIGURATION=Release ACTION=install $good
expect pass "Custom configuration with real identity" CONFIGURATION=Staff ACTION=install $good
}
expect fail "Upstream team" CONFIGURATION=Release ORG_TEAM_ID=MN3X4648SC DEVELOPMENT_TEAM=MN3X4648SC \
  ORG_BUNDLE_ID=health.frontier.Maccy PRODUCT_BUNDLE_IDENTIFIER=health.frontier.Maccy
expect fail "Placeholder with capitals" CONFIGURATION=Release ORG_TEAM_ID=ABCDE12345 DEVELOPMENT_TEAM=ABCDE12345 \
  ORG_BUNDLE_ID=Invalid.example.Maccy PRODUCT_BUNDLE_IDENTIFIER=Invalid.example.Maccy
expect fail "Upstream bundle ID with capitals" CONFIGURATION=Release ORG_TEAM_ID=ABCDE12345 DEVELOPMENT_TEAM=ABCDE12345 \
  ORG_BUNDLE_ID=Org.P0deje.Maccy PRODUCT_BUNDLE_IDENTIFIER=Org.P0deje.Maccy
expect fail "Team overridden separately" CONFIGURATION=Release ORG_TEAM_ID=ABCDE12345 DEVELOPMENT_TEAM=ZZZZZ99999 \
  ORG_BUNDLE_ID=health.frontier.Maccy PRODUCT_BUNDLE_IDENTIFIER=health.frontier.Maccy
expect fail "Bundle ID overridden separately" CONFIGURATION=Release ORG_TEAM_ID=ABCDE12345 DEVELOPMENT_TEAM=ABCDE12345 \
  ORG_BUNDLE_ID=health.frontier.Maccy PRODUCT_BUNDLE_IDENTIFIER=health.frontier.Other
expect fail "Empty team" CONFIGURATION=Release ORG_TEAM_ID= DEVELOPMENT_TEAM= \
  ORG_BUNDLE_ID=health.frontier.Maccy PRODUCT_BUNDLE_IDENTIFIER=health.frontier.Maccy

if [ "$failures" -ne 0 ]; then exit 1; fi
echo "check-release-identity: all cases behaved as expected"
