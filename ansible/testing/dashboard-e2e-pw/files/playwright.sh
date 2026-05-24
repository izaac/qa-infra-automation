#!/bin/bash
# Playwright test runner — invoked by the Dashboard E2E (PW) pipeline.
#
# Runs from the dashboard-e2e-pw repo root inside the Docker container.
# Reads GREP_TAGS from the environment (.env file produced by Ansible) and
# passes it to `playwright test --grep`.

set -e
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND (exit $?)"' ERR

echo "[playwright.sh] PWD=$(pwd)"
echo "[playwright.sh] node $(node -v)"
echo "[playwright.sh] kubectl $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1)"

# Install dependencies (Playwright's base image bundles browsers, but the spec
# repo brings its own deps — fixtures, helpers, qase reporter, etc.).
echo "[playwright.sh] Installing test dependencies..."
if ! NODE_NO_WARNINGS=1 yarn install --frozen-lockfile --silent; then
	echo "[playwright.sh] ERROR: yarn install failed in $(pwd)"
	echo "[playwright.sh] Node: $(node -v), Yarn: $(yarn --version)"
	echo "[playwright.sh] package.json exists: $(test -f package.json && echo yes || echo no)"
	echo "[playwright.sh] yarn.lock exists: $(test -f yarn.lock && echo yes || echo no)"
	exit 1
fi

export FORCE_COLOR=1
export NODE_OPTIONS="--max-old-space-size=4096"

# GREP_TAGS comes from the .env file produced by Ansible. Fail loudly if it is
# missing — running playwright with no grep would launch the full suite, which
# is almost never what we want in CI.
if [ -z "${GREP_TAGS:-}" ]; then
	echo "[playwright.sh] ERROR: GREP_TAGS env not set."
	echo "[playwright.sh] Check that the runner was invoked with --env-file <ansible-generated .env>."
	exit 1
fi

GREP_ARGS=(--grep "${GREP_TAGS}")

# Run Playwright and capture the exit code.
# `--config=playwright.config.jenkins.ts` wires up JUnit + (optional) Qase reporters.
set +e
npx playwright test --config=playwright.config.jenkins.ts "${GREP_ARGS[@]}"
EXIT_CODE=$?
set -e

echo "PLAYWRIGHT EXIT CODE: $EXIT_CODE"

# Make sure the JUnit file exists in the expected path — Ansible's run-tests.yml
# stat's this location before copying it to the workspace.
if [ -f "e2e/jenkins/reports/junit/results.xml" ]; then
	echo "[playwright.sh] JUnit report at e2e/jenkins/reports/junit/results.xml"
else
	echo "[playwright.sh] WARNING: no JUnit report produced; Ansible artifact copy will be skipped."
fi

exit $EXIT_CODE
