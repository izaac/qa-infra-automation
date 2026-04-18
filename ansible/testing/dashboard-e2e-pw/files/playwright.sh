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

# Ensure Chrome is available (safety net if image version drifts)
npx playwright install chrome 2>/dev/null || true

echo "[playwright.sh] node $(node -v), yarn $(yarn --version)"
echo "[playwright.sh] kubectl $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' || echo 'not available')"

export FORCE_COLOR=1
export NODE_OPTIONS="--max-old-space-size=4096"
# Use container's pre-installed browsers, not host paths leaked via volume mount
export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
unset PLAYWRIGHT_CHROMIUM_PATH

# Tags from .env (GREP_TAGS)
TAGS="${GREP_TAGS:-}"
echo "[playwright.sh] GREP_TAGS=${TAGS}"

# Build grep args for tag filtering
GREP_ARGS=()
if [ -n "$TAGS" ]; then
	GREP_ARGS=(--grep "$TAGS")
fi

# Run Playwright
set +e
npx playwright test \
	--config=playwright.config.jenkins.ts \
	"${GREP_ARGS[@]}"
EXIT_CODE=$?
set -e

echo "PLAYWRIGHT EXIT CODE: $EXIT_CODE"

# Copy JUnit results to root for collection
if [ -f "test-results/results.xml" ]; then
	cp test-results/results.xml results.xml
fi

exit $EXIT_CODE
