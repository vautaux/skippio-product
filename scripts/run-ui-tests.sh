#!/bin/bash
# Runs the fan-journey UI test against the real Supabase project.
#
# It creates a throwaway confirmed user (service role key from .env), runs the test as
# that user, and always deletes the user afterwards. Screenshots land in /tmp/shots.
# Stripe's hosted page is outside the app, so payment is settled with a signed test webhook.
#
# Usage: scripts/run-ui-tests.sh [simulator-udid]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# .env is parsed, not sourced, so values with spaces (Google app passwords) are fine.
eval "$(python3 scripts/loadenv.py .env 2>/dev/null)"

SIM="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 (' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}"
XCODEGEN="$(command -v xcodegen || echo "$ROOT/../tools/xcodegen/bin/xcodegen")"

admin() {
  curl -s -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" "$@"
}

EMAIL="uitest-$(date +%s)@example.com"
PASS="UiTestPass1!$(date +%s)"
RESP=$(admin -X POST "$SUPABASE_PROJECT_URL/auth/v1/admin/users" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"email_confirm\":true,\"user_metadata\":{\"full_name\":\"E2E Tester\"}}")
USER_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])") || { echo "could not create test user"; exit 1; }
cleanup() { admin -X DELETE "$SUPABASE_PROJECT_URL/auth/v1/admin/users/$USER_ID" >/dev/null; echo "test user deleted"; }
trap cleanup EXIT

cd ios/SkippioFan || exit 1
"$XCODEGEN" generate --spec project.yml >/dev/null
rm -rf /tmp/shots && mkdir -p /tmp/shots

# Build first, then run the tests without rebuilding, so what runs is exactly what was built.
xcodebuild build-for-testing -project SkippioFan.xcodeproj -scheme SkippioFan \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ./build 2>&1 | grep -E "error:|BUILD FAILED"

# The simulator can keep an older install around; start from a clean slate.
xcrun simctl uninstall "$SIM" com.mohammadnaimi.skippiofan >/dev/null 2>&1
# The keychain survives uninstalling, and it holds the saved sign-in session.
# (simctl only clears it while the simulator is shut down.)
xcrun simctl shutdown "$SIM" >/dev/null 2>&1
xcrun simctl keychain "$SIM" reset >/dev/null 2>&1
xcrun simctl boot "$SIM" >/dev/null 2>&1
# Pretend to be in central Dublin so distance labels show up.
# Install now so the location permission can be granted up front (no prompt over Home).
xcrun simctl install "$SIM" ./build/Build/Products/Debug-iphonesimulator/SkippioFan.app >/dev/null 2>&1
xcrun simctl privacy "$SIM" grant location com.mohammadnaimi.skippiofan >/dev/null 2>&1
xcrun simctl location "$SIM" set 53.3498,-6.2603 >/dev/null 2>&1

TEST_RUNNER_E2E_EMAIL="$EMAIL" TEST_RUNNER_E2E_PASSWORD="$PASS" \
  TEST_RUNNER_E2E_SUPABASE_URL="$SUPABASE_PROJECT_URL" TEST_RUNNER_E2E_ANON_KEY="$SUPABASE_ANON_KEY" \
  TEST_RUNNER_E2E_WHSEC="$STRIPE_WEBHOOK_SECRET" xcodebuild test-without-building \
  -project SkippioFan.xcodeproj -scheme SkippioFan \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ./build 2>&1 \
  | tee /tmp/ui_test.log \
  | grep -E "error:|Test Case.*(passed|failed)|Executed|TEST (SUCCEEDED|FAILED)|BUILD FAILED"
