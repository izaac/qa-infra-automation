#!/bin/bash

set -e
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND (exit $?)"' ERR

echo "[playwright.sh] Installing test dependencies..."
echo "[playwright.sh] PWD=$(pwd)"

if ! yarn install --frozen-lockfile --silent; then
	echo "[playwright.sh] ERROR: yarn install failed"
	echo "[playwright.sh] Node: $(node -v), Yarn: $(yarn --version)"
	exit 1
fi

# Ensure Chromium is available (safety net if image version drifts)
npx playwright install --force chromium 2>/dev/null || true

echo "[playwright.sh] node $(node -v), yarn $(yarn --version)"
echo "[playwright.sh] kubectl $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' || echo 'not available')"

export FORCE_COLOR=1
export NODE_OPTIONS="--max-old-space-size=4096"
# Use container's pre-installed browsers, not host paths leaked via volume mount
export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
unset PLAYWRIGHT_CHROMIUM_PATH

# GREP_TAGS is parsed by playwright.config.ts (supports Cypress-style +/-@ syntax).
# Do NOT pass --grep on the CLI — it would override the config's parseGrepTags().
echo "[playwright.sh] GREP_TAGS=${GREP_TAGS:-<none>}"

# Run Playwright (base config — no jenkins override needed)
set +e
npx playwright test "$@"
EXIT_CODE=$?
set -e

echo "PLAYWRIGHT EXIT CODE: $EXIT_CODE"

exit $EXIT_CODE
