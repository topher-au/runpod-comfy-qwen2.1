#!/usr/bin/env bash
#
# release.sh - build, push and release the runpod-comfy-qwen2.1 worker image.
#
#   ./release.sh                 build + push the image, roll the endpoint onto it
#   ./release.sh --dry-run       resolve everything, change nothing (no build)
#   ./release.sh --skip-build    release a tag that is already pushed
#   ./release.sh --tag latest    release an explicit tag instead of <timestamp>
#   ./release.sh --force         release even if the template is already on it
#   ./release.sh --help
#
# Configuration is read from .env next to this script (see .env.example).
# Anything already exported in the environment, or given on the command line,
# wins over .env.
#
# Exit codes: 0 ok, 1 failure.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
cd "$SCRIPT_DIR"

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s  %s\n' "$(ts)" "$*"; }
warn() { printf '%s  WARN: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s  ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }
trap 'rc=$?; printf "%s  ERROR: exit %s at %s line %s\n" "$(ts)" "$rc" "${0##*/}" "$LINENO" >&2' ERR

usage() {
	sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

# --- configuration ----------------------------------------------------------

# Read KEY=VALUE lines without executing the file. Existing environment values
# are never overwritten.
load_env() {
	local file=$1 line key val
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		case $line in ''|'#'*) continue ;; esac
		line=${line#export }
		case $line in *=*) ;; *) continue ;; esac
		key=${line%%=*}
		val=${line#*=}
		key=$(printf '%s' "$key" | tr -d '[:space:]')
		case $key in [A-Za-z_][A-Za-z0-9_]*) ;; *) continue ;; esac
		val=${val#"${val%%[![:space:]]*}"}
		val=${val%"${val##*[![:space:]]}"}
		case $val in
			\"*\") val=${val#\"}; val=${val%\"} ;;
			\'*\') val=${val#\'}; val=${val%\'} ;;
		esac
		if [ -z "${!key+x}" ]; then
			printf -v "$key" '%s' "$val"
			export "${key?}"
		fi
	done <"$file"
}

DRY_RUN=""
SKIP_BUILD=""
FORCE=""
TAG=""
RUNPOD_ENDPOINT_ID=""

while [ $# -gt 0 ]; do
	case $1 in
		--dry-run)      DRY_RUN=1; shift ;;
		--skip-build)   SKIP_BUILD=1; shift ;;
		--force)        FORCE=1; shift ;;
		--tag)          TAG=${2?--tag requires a value}; shift 2 ;;
		--tag=*)        TAG=${1#*=}; shift ;;
		--endpoint)     RUNPOD_ENDPOINT_ID=${2?--endpoint requires a value}; shift 2 ;;
		--endpoint=*)   RUNPOD_ENDPOINT_ID=${1#*=}; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown argument: $1 (try --help)" ;;
	esac
done

load_env "$SCRIPT_DIR/.env"

IMAGE=${IMAGE:-topherau/runpod-comfy-qwen2.1}
TAG=${TAG:-$(date +%Y%m%d%H%M)}
API=${RUNPOD_API:-https://rest.runpod.io/v1}
KEY=${RUNPOD_API_KEY:-}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-180}
LOCK_FILE=${LOCK_FILE:-$SCRIPT_DIR/.release.lock}

# A dry run resolves everything but never builds or writes.
if [ -n "$DRY_RUN" ]; then
	SKIP_BUILD=1
fi

# --- preflight --------------------------------------------------------------

[ -n "$KEY" ] || die "RUNPOD_API_KEY is not set - put it in $SCRIPT_DIR/.env (cp .env.example .env)"
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"
if [ -z "$SKIP_BUILD" ]; then
	command -v docker >/dev/null || die "docker is required (or pass --skip-build)"
fi

exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
flock -n 9 || die "another release is already running (lock: $LOCK_FILE)"

# --- runpod api -------------------------------------------------------------

api() {
	curl -fsS --retry 3 --retry-delay 2 --retry-connrefused \
		-H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$@"
}
# Endpoint-bound templates are invisible to the plain template endpoints, so the
# query parameter is mandatory for both reads and writes.
template() { api "$API/templates/$1?includeEndpointBoundTemplates=true"; }

resolve_endpoint() {
	if [ -n "$RUNPOD_ENDPOINT_ID" ]; then
		printf '%s' "$RUNPOD_ENDPOINT_ID"
		return 0
	fi
	local eps tps ep
	eps=$(api "$API/endpoints") || die "cannot list endpoints"
	tps=$(api "$API/templates?includeEndpointBoundTemplates=true") || die "cannot list templates"
	ep=$(jq -nr --argjson eps "$eps" --argjson tps "$tps" --arg repo "$IMAGE" '
		[$eps[] as $e | $tps[] | select(.id == $e.templateId)
			| select((.imageName // "") | test($repo)) | $e.id]
		| unique | if length == 1 then .[0] else empty end')
	if [ -z "$ep" ]; then
		jq -nr --argjson eps "$eps" --argjson tps "$tps" --arg repo "$IMAGE" '
			$eps[] as $e | $tps[] | select(.id == $e.templateId)
				| select((.imageName // "") | test($repo))
				| "    endpoint \($e.id) \"\($e.name)\"  template \(.id)  \(.imageName)"' >&2
		die "no single endpoint runs $IMAGE - set RUNPOD_ENDPOINT_ID in .env (candidates above)"
	fi
	printf '%s' "$ep"
}

# --- build ------------------------------------------------------------------

if [ -n "$SKIP_BUILD" ]; then
	if [ -n "$DRY_RUN" ]; then
		log "dry run: would build and push $IMAGE:$TAG (also :latest)"
	else
		log "skipping build, releasing existing tag $IMAGE:$TAG"
	fi
else
	log "building and pushing $IMAGE:$TAG (also tagging :latest)"
	build_args=(--push -t "$IMAGE:latest" -t "$IMAGE:$TAG")
	if [ -n "${PLATFORM:-}" ]; then
		build_args+=(--platform "$PLATFORM")
	fi
	docker build "${build_args[@]}" .
	log "pushed $IMAGE:$TAG"
	if [ -z "${SKIP_PUSH_CHECK:-}" ]; then
		docker manifest inspect "$IMAGE:$TAG" >/dev/null 2>&1 \
			|| die "$IMAGE:$TAG is not visible in the registry - refusing to release"
	fi
fi

# --- release ----------------------------------------------------------------

log "resolving the serverless endpoint for $IMAGE"
EP=$(resolve_endpoint)
EP_JSON=$(api "$API/endpoints/$EP") || die "cannot read endpoint $EP"
NAME=$(jq -r '.name' <<<"$EP_JSON")
TPL=$(jq -r '.templateId // empty' <<<"$EP_JSON")
VERSION=$(jq -r '.version // 0' <<<"$EP_JSON")
[ -n "$TPL" ] || die "endpoint $EP has no templateId"

OLD_IMAGE=$(template "$TPL" | jq -r '.imageName // empty') || die "cannot read template $TPL"
[ -n "$OLD_IMAGE" ] || die "template $TPL has no image"

# Keep whatever registry prefix the endpoint already uses (RunPod writes
# docker.io/ itself), so releases stay consistent.
case $OLD_IMAGE in
	docker.io/*) NEW_IMAGE="docker.io/$IMAGE:$TAG" ;;
	*)           NEW_IMAGE="$IMAGE:$TAG" ;;
esac

log "endpoint $EP \"$NAME\" (version $VERSION), template $TPL"
log "current image: $OLD_IMAGE"

if [ "$OLD_IMAGE" = "$NEW_IMAGE" ] && [ -z "$FORCE" ]; then
	log "already on $NEW_IMAGE - nothing to release (use --force to re-release)"
	exit 0
fi

if [ -n "$DRY_RUN" ]; then
	log "dry run: would release $NEW_IMAGE"
	exit 0
fi

log "releasing $NEW_IMAGE"
api -X PATCH -d "$(jq -nc --arg i "$NEW_IMAGE" '{imageName: $i}')" \
	"$API/templates/$TPL?includeEndpointBoundTemplates=true" >/dev/null \
	|| die "template update failed"

CURRENT=$(template "$TPL" | jq -r '.imageName // empty') || die "cannot verify template $TPL"
[ "$CURRENT" = "$NEW_IMAGE" ] || die "release failed: template $TPL still points at $CURRENT"

# New workers pick the image up as they start; a scale-to-zero endpoint may not
# bump its version until the next request, so this is best effort.
if [ "$WAIT_TIMEOUT" -gt 0 ]; then
	log "waiting up to ${WAIT_TIMEOUT}s for the rolling release to start"
	deadline=$((SECONDS + WAIT_TIMEOUT))
	NEW_VERSION=$VERSION
	while [ "$SECONDS" -lt "$deadline" ]; do
		NEW_VERSION=$(api "$API/endpoints/$EP" | jq -r '.version // 0')
		if [ "$NEW_VERSION" -gt "$VERSION" ]; then
			break
		fi
		sleep 5
	done
	if [ "$NEW_VERSION" -gt "$VERSION" ]; then
		log "endpoint version $VERSION -> $NEW_VERSION, workers are rolling"
	else
		warn "endpoint version still $VERSION after ${WAIT_TIMEOUT}s - workers start on next request"
	fi
fi

log "released $NEW_IMAGE to $EP \"$NAME\" (template $TPL)"
