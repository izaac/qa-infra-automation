#!/bin/bash

set -e
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# Source shared utilities relative to the script's location
source "$(dirname "$0")/utils.sh"

pwd
cd "dashboard"

# Install test dependencies inside the container (correct platform binaries for Debian/glibc)
echo "[cypress.sh] Installing test dependencies..."
echo "[cypress.sh] PWD=$(pwd)"
if ! (cd cypress && yarn install --frozen-lockfile); then
  echo "[cypress.sh] ERROR: yarn install failed in $(pwd)/cypress"
  echo "[cypress.sh] Node: $(node -v), Yarn: $(yarn --version)"
  echo "[cypress.sh] package.json exists: $(test -f cypress/package.json && echo yes || echo no)"
  echo "[cypress.sh] yarn.lock exists: $(test -f cypress/yarn.lock && echo yes || echo no)"
  exit 1
fi
ln -sf cypress/node_modules node_modules

# Use test deps from cypress/node_modules
export NODE_PATH="${PWD}/cypress/node_modules:${NODE_PATH:-}"
export PATH="${PWD}/cypress/node_modules/.bin:${PATH}"

kubectl version --client=true
kubectl get nodes

node -v

env

export FORCE_COLOR=1
export PERCY_LOGLEVEL=warn
export PERCY_SKIP_UPDATE_CHECK=true
export DEBUG=@cypress/grep

# Capture the tags from the placeholder (replaced by playbook setup-test-env.yml)
TAGS="CYPRESSTAGS"

# Normalize tags (strip @bypass, handle spaces)
TAGS=$(clean_tags "${TAGS}")

export CYPRESS_grepTags="$TAGS"

# Pre-filter specs by tag so Cypress only opens matching files.
# This bypasses the Cypress 11 bug where config.specPattern modifications
# from setupNodeEvents are ignored.
SPEC_ARG=()
if [ -n "$TAGS" ]; then
	if ! FILTERED_SPECS=$(node --no-warnings --experimental-strip-types cypress/jenkins/grep-filter.ts 2>&1); then
		echo "[cypress.sh] ERROR: grep-filter.ts failed:"
		echo "$FILTERED_SPECS"
		exit 1
	fi
	if [ -n "$FILTERED_SPECS" ]; then
		echo "grep-filter: will run --spec $FILTERED_SPECS"
		SPEC_ARG=(--spec "$FILTERED_SPECS")
	else
		echo "grep-filter: no matching specs found for tags '$TAGS', running all specs"
	fi
fi

# Run Cypress and capture the exit code
set +e

if [ -n "$PERCY_TOKEN" ]; then
	percy exec -q -- cypress run --browser chrome --config-file cypress/jenkins/cypress.config.jenkins.ts "${SPEC_ARG[@]}"
else
	cypress run --browser chrome --config-file cypress/jenkins/cypress.config.jenkins.ts "${SPEC_ARG[@]}"
fi
EXIT_CODE=$?
set -e

echo "CYPRESS EXIT CODE: $EXIT_CODE"

# Merge JUnit reports inside the container (Node.js is available here)
echo "[cypress.sh] Merging JUnit reports..."
if ! npx --no-install jrm results.xml "cypress/jenkins/reports/junit/junit-*"; then
  echo "WARNING: jrm merge failed — individual junit-*.xml files may still be available"
  ls -la cypress/jenkins/reports/junit/ 2>/dev/null || echo "  (report directory not found)"
fi

exit $EXIT_CODE
