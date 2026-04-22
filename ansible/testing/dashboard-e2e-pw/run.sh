#!/bin/sh
# Wrapper to run the Playwright E2E playbook inside a container.
# Works with Docker and Podman — no local tool installation needed.
#
# Commands:
#   ./run.sh                          # full pipeline (provision → test → cleanup)
#   ./run.sh provision                # provision infra only
#   ./run.sh setup                    # clone repo + build test image
#   ./run.sh test                     # re-run tests (via ansible, no live output)
#   ./run.sh stream                   # setup + test with live Playwright output
#   ./run.sh stream provision         # provision + setup + test, live output
#   ./run.sh provision setup          # provision + setup (no test)
#   ./run.sh provision setup test     # everything except cleanup
#   ./run.sh destroy                  # tear down infrastructure
#   ./run.sh build                    # rebuild the runner image
#   ./run.sh results                  # open the HTML test report
#   ./run.sh clean                    # remove local artifacts (reports, clone, .env)
#
# Extra ansible flags pass through:
#   ./run.sh test -v                  # verbose
#   ./run.sh test --check             # dry-run
#
# Prerequisites:
#   - Docker or Podman
#   - vars.yaml in this directory (cp vars.yaml.example vars.yaml)
#   - AWS credentials exported (for provision): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMAGE_NAME="playwright-e2e-runner"
VARS_FILE="${SCRIPT_DIR}/vars.yaml"

# --- Detect container runtime ---
detect_runtime() {
	if command -v podman >/dev/null 2>&1; then
		RUNTIME="podman"
	elif command -v docker >/dev/null 2>&1; then
		RUNTIME="docker"
	else
		echo "" >&2
		echo "  You need Docker or Podman to run this." >&2
		echo "" >&2
		exit 1
	fi
}

# --- Detect container socket ---
detect_socket() {
	if [ "$RUNTIME" = "podman" ]; then
		for _sock in \
			"$(podman info -f '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)" \
			"/run/user/$(id -u)/podman/podman.sock" \
			"/run/podman/podman.sock"; do
			[ -n "$_sock" ] && [ -S "$_sock" ] && {
				SOCKET="$_sock"
				return
			}
		done
		echo "ERROR: Podman socket not found." >&2
		exit 1
	else
		SOCKET="/var/run/docker.sock"
		if [ ! -S "$SOCKET" ]; then
			echo "ERROR: Docker socket not found at $SOCKET" >&2
			exit 1
		fi
	fi
}

# --- Build image if needed ---
build_image() {
	if ! $RUNTIME image inspect "$IMAGE_NAME" >/dev/null 2>&1 || [ "${_FORCE_BUILD:-}" = "1" ]; then
		echo "[run] Building ${IMAGE_NAME} image..."
		$RUNTIME build -f "${SCRIPT_DIR}/Dockerfile.quickstart" -t "$IMAGE_NAME" "$SCRIPT_DIR"
	fi
}

# --- Run playbook inside container ---
run_playbook() {
	_creds_file="${SCRIPT_DIR}/.creds.yml"
	trap 'rm -f "${_creds_file}"' EXIT
	: > "${_creds_file}"
	chmod 600 "${_creds_file}"

	yaml_cred_escape() { printf '%s' "${1}" | sed "s/'/''''/g"; }

	[ -n "${QASE_TOKEN:-}" ]                && printf "qase_token: '%s'\n"            "$(yaml_cred_escape "${QASE_TOKEN}")"                >> "${_creds_file}"
	[ -n "${AZURE_CLIENT_ID:-}" ]           && printf "azure_client_id: '%s'\n"       "$(yaml_cred_escape "${AZURE_CLIENT_ID}")"           >> "${_creds_file}"
	[ -n "${AZURE_CLIENT_SECRET:-}" ]       && printf "azure_client_secret: '%s'\n"   "$(yaml_cred_escape "${AZURE_CLIENT_SECRET}")"       >> "${_creds_file}"
	[ -n "${AZURE_AKS_SUBSCRIPTION_ID:-}" ] && printf "azure_subscription_id: '%s'\n" "$(yaml_cred_escape "${AZURE_AKS_SUBSCRIPTION_ID}")" >> "${_creds_file}"
	[ -n "${GKE_SERVICE_ACCOUNT:-}" ]       && printf "gke_service_account: '%s'\n"   "$(yaml_cred_escape "${GKE_SERVICE_ACCOUNT}")"       >> "${_creds_file}"

	[ ! -s "${_creds_file}" ] && printf '{}\n' > "${_creds_file}"

	$RUNTIME run --rm -it \
		-v "${SOCKET}:/var/run/docker.sock" \
		-v "${VARS_FILE}:/playbook/vars.yaml:ro" \
		-v "${_creds_file}:/playbook/.creds.yml:ro" \
		-v "${SCRIPT_DIR}:/playbook" \
		-v "${REPO_ROOT}:/qa-infra" \
		-e QA_INFRA_DIR=/qa-infra \
		-e HOST_DASHBOARD_DIR="${SCRIPT_DIR}/dashboard-e2e-pw" \
		-e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
		-e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
		-e GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}" \
		"$IMAGE_NAME" \
		--extra-vars "@/playbook/.creds.yml" \
		"$@"

	rm -f "${_creds_file}"
}

# --- Stream Playwright tests with live output ---
stream_playwright() {
	echo ""
	echo "[run] Streaming Playwright tests..."
	echo ""

	if ! $RUNTIME image inspect "playwright-test:${EXECUTOR_TAG:-0}" >/dev/null 2>&1; then
		echo "ERROR: playwright-test:${EXECUTOR_TAG:-0} image not found — run setup first" >&2
		exit 1
	fi
	if [ ! -f "${SCRIPT_DIR}/.env" ]; then
		echo "ERROR: .env not found — run setup first" >&2
		exit 1
	fi

	_host="$(grep '^rancher_host:' "$VARS_FILE" 2>/dev/null | head -1 | sed "s/^rancher_host:[[:space:]]*//" | tr -d "\"'" || echo "playwright-e2e")"
	_name="playwright-$(echo "$_host" | sed 's/[^a-zA-Z0-9_.-]/-/g')"
	$RUNTIME rm -f "$_name" 2>/dev/null || true

	# Extra args after "stream" are forwarded via entrypoint → playwright.sh "$@" → npx playwright test "$@"
	exec $RUNTIME run --rm -it \
		--name "$_name" \
		--shm-size=2g \
		--env-file "${SCRIPT_DIR}/.env" \
		-v "${SCRIPT_DIR}/dashboard-e2e-pw:/e2e" \
		-w /e2e \
		"playwright-test:${EXECUTOR_TAG:-0}" \
		"$@"
}

# --- Main ---
detect_runtime
detect_socket

TAGS=""
STREAM=""
_FORCE_BUILD=""
_BUILD_ONLY=""
EXECUTOR_TAG="${EXECUTOR_NUMBER:-0}"
while [ $# -gt 0 ]; do
	case "$1" in
	provision | setup | test)
		TAGS="${TAGS:+${TAGS},}$1"
		shift
		;;
	stream)
		STREAM=1
		shift
		;;
	destroy)
		TAGS="cleanup,never"
		shift
		;;
	build)
		_FORCE_BUILD=1
		_BUILD_ONLY=1
		shift
		;;
	results)
		_report="${SCRIPT_DIR}/dashboard-e2e-pw/playwright-report/index.html"
		if [ -f "$_report" ]; then
			open "$_report" 2>/dev/null || xdg-open "$_report" 2>/dev/null || echo "$_report"
		else
			echo "No report found. Run tests first: ./run.sh stream"
		fi
		exit 0
		;;
	clean)
		rm -rf "${SCRIPT_DIR}/dashboard-e2e-pw" "${SCRIPT_DIR}/outputs" "${SCRIPT_DIR}/.env"
		echo "[run] Local artifacts cleaned."
		exit 0
		;;
	--build)
		_FORCE_BUILD=1
		shift
		;;
	-h | --help)
		sed -n '2,/^$/s/^# //p' "$0"
		exit 0
		;;
	*)
		break
		;;
	esac
done

# stream without explicit stages defaults to setup,test
if [ -n "$STREAM" ] && [ -z "$TAGS" ]; then
	TAGS="setup,test"
fi

if [ ! -f "$VARS_FILE" ]; then
	echo "" >&2
	echo "  vars.yaml not found:" >&2
	echo "    cp vars.yaml.example vars.yaml" >&2
	echo "    \$EDITOR vars.yaml" >&2
	echo "" >&2
	exit 1
fi

case "${TAGS}" in
*provision* | "")
	if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
		echo "WARNING: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set." >&2
	fi
	;;
esac

build_image

if [ -n "$_BUILD_ONLY" ]; then
	echo "[run] Image rebuilt. Done."
	exit 0
fi

mkdir -p "${SCRIPT_DIR}/outputs"

echo "[run] Using ${RUNTIME} (socket: ${SOCKET})"
echo "[run] vars.yaml: ${VARS_FILE}"
echo ""

TAG_ARGS=""
if [ -n "$TAGS" ]; then
	TAG_ARGS="--tags ${TAGS}"
fi

if [ -n "$STREAM" ]; then
	# Run everything except test via playbook, then stream Playwright directly
	# shellcheck disable=SC2086
	run_playbook --skip-tags test ${TAG_ARGS}
	stream_playwright "$@"
else
	# shellcheck disable=SC2086
	run_playbook ${TAG_ARGS} "$@"
fi
