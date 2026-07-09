#!/usr/bin/env bash
# Build linux/amd64 Plexus and push to the TrueNAS registry (optional path).
#
# Preferred on this lab: build ON TrueNAS and tag locally as plexus:xai-latest
# (see docs/DEPLOY_TRUENAS.md). Registry HTTP push often fails without
# insecure-registries. This script is for hosts that have Docker + registry access.
#
# Usage:
#   ./scripts/deploy-truenas-image.sh              # build + push
#   ./scripts/deploy-truenas-image.sh --redeploy  # build + push + Portainer pull
#
# Env:
#   REGISTRY          default 192.168.66.66:5000
#   IMAGE_NAME        default plexus
#   TAG_PREFIX        default xai
#   PORTAINER_URL     default https://192.168.66.66:31015
#   PORTAINER_TOKEN   required for --redeploy (or load ~/.config/mcp-keys.env)
#   PORTAINER_STACK_ID default 94
#   PORTAINER_ENDPOINT_ID default 3

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REGISTRY="${REGISTRY:-192.168.66.66:5000}"
IMAGE_NAME="${IMAGE_NAME:-plexus}"
TAG_PREFIX="${TAG_PREFIX:-xai}"
PORTAINER_URL="${PORTAINER_URL:-https://192.168.66.66:31015}"
PORTAINER_STACK_ID="${PORTAINER_STACK_ID:-94}"
PORTAINER_ENDPOINT_ID="${PORTAINER_ENDPOINT_ID:-3}"
REDEPLOY=0

for arg in "$@"; do
  case "$arg" in
    --redeploy) REDEPLOY=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -f "${HOME}/.config/mcp-keys.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source "${HOME}/.config/mcp-keys.env"
  set +a
fi

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION="${TAG_PREFIX}-${SHA}"
LATEST_TAG="${REGISTRY}/${IMAGE_NAME}:${TAG_PREFIX}-latest"
SHA_TAG="${REGISTRY}/${IMAGE_NAME}:${TAG_PREFIX}-${SHA}"

echo "==> Building ${LATEST_TAG} (platform linux/amd64, APP_VERSION=${VERSION})"
docker build \
  --platform linux/amd64 \
  --build-arg "APP_VERSION=${VERSION}" \
  -t "${LATEST_TAG}" \
  -t "${SHA_TAG}" \
  .

echo "==> Pushing ${LATEST_TAG}"
docker push "${LATEST_TAG}"
echo "==> Pushing ${SHA_TAG}"
docker push "${SHA_TAG}"

echo "==> Done. Tags:"
echo "    ${LATEST_TAG}"
echo "    ${SHA_TAG}"

if [[ "${REDEPLOY}" -eq 1 ]]; then
  if [[ -z "${PORTAINER_TOKEN:-}" ]]; then
    echo "PORTAINER_TOKEN not set; skip redeploy. Set it or pass only build+push." >&2
    exit 1
  fi

  echo "==> Redeploying Portainer stack ${PORTAINER_STACK_ID} (pullImage=true)"
  python3 - "${PORTAINER_URL}" "${PORTAINER_TOKEN}" "${PORTAINER_STACK_ID}" "${PORTAINER_ENDPOINT_ID}" <<'PY'
import json, ssl, sys, urllib.request

base, token, stack_id, endpoint_id = sys.argv[1:5]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def api(method: str, path: str, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        f"{base.rstrip('/')}/api{path}",
        data=body,
        method=method,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": token,
        },
    )
    with urllib.request.urlopen(req, context=ctx, timeout=120) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


stack = api("GET", f"/stacks/{stack_id}")
file_info = api("GET", f"/stacks/{stack_id}/file")
content = file_info.get("StackFileContent") or ""
if not content:
    raise SystemExit("empty stack file content")

# Preserve env from the live stack definition
env = stack.get("Env") or []

result = api(
    "PUT",
    f"/stacks/{stack_id}?endpointId={endpoint_id}",
    {
        "stackFileContent": content,
        "env": env,
        "prune": False,
        "pullImage": True,
    },
)
print(f"Stack updated: Id={result.get('Id')} Status={result.get('Status')}")
PY

  echo "==> Health check"
  curl -sS -m 15 "http://192.168.66.66:4000/health" || true
  echo
fi

echo "Portainer: update stack 'plexus' (94) with image ${LATEST_TAG} if not already."
echo "Verify: curl -sS http://192.168.66.66:4000/health"
