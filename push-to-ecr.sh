#!/usr/bin/env bash
#
# push-to-ecr.sh — package one or more Spectro Cloud packs, push them to an ECR
# OCI registry (via ORAS), and optionally trigger a registry sync in Palette.
#
set -euo pipefail

# ---------- output helpers ----------
red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; clear=$'\033[0m'
info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$green" "$*" "$clear"; }
warn() { printf '%s%s%s\n' "$yellow" "$*" "$clear" >&2; }
die()  { printf '%sERROR: %s%s\n' "$red" "$*" "$clear" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
push-to-ecr.sh — package Spectro Cloud packs, push them to ECR, and optionally
sync the registry in Palette.

Usage:
  ./push-to-ecr.sh [options] [PACK_DIR ...]

  PACK_DIR   One or more pack directories (each contains a pack.json).
             If none are given, the current directory is used.

Push options:
  -r, --registry NAME    ECR registry namespace        (default: custeng-sa-oci)
      --region REGION    AWS region                    (default: eu-west-2)
  -b, --base-path PATH   Repo base path under registry (default: spectro-packs/archive)
      --lean             Exclude the unpacked charts/<chart>/ tree (keeps charts/*.tgz)

Palette sync options:
  -s, --sync             Trigger a Palette registry sync after a successful push
      --sync-only        Skip pushing; only trigger the Palette sync
      --wait             Poll sync status until it completes (with --sync/--sync-only)
      --registry-name N  Palette registry display name (resolved to its UID via API)
      --registry-type T  ecr | basic                   (default: ecr)
      --project-uid UID  Scope the API calls to a project (omit for tenant scope)
      --palette-host H   Palette API host               (default: api.spectrocloud.com)
      --sync-timeout S   Seconds to wait with --wait     (default: 600)

General:
  -y, --yes              Skip the confirmation prompt (required when non-interactive)
  -h, --help             Show this help and exit

Configuration precedence (highest first):
  CLI flag  >  environment variable  >  .env file  >  built-in default
  Keys: REGISTRY_NAME, AWS_DEFAULT_REGION, PACK_BASE_PATH,
        PALETTE_API_KEY, PALETTE_HOST, PALETTE_REGISTRY_NAME,
        PALETTE_REGISTRY_TYPE, PALETTE_PROJECT_UID
  PALETTE_API_KEY must come from the environment or .env (never a CLI flag).
  The .env file is loaded from $ENV_FILE or the script directory's .env.

Examples:
  ./push-to-ecr.sh ../pack-central/packs/kata-deploy-3.32.0
  ./push-to-ecr.sh --lean -y ../pack-central/packs/*/
  ./push-to-ecr.sh --sync --registry-name "SA OCI Registry" -y ./mypack-1.0.0
  ./push-to-ecr.sh --sync-only --wait --registry-name "SA OCI Registry" -y
EOF
}

# ---------- defaults ----------
DEF_REGISTRY_NAME="custeng-sa-oci"
DEF_REGION="eu-west-2"
DEF_BASE_PATH="spectro-packs/archive"
DEF_PALETTE_HOST="api.spectrocloud.com"
DEF_PALETTE_TYPE="ecr"

# ---------- load .env (env vars win over .env; .env wins over defaults) ----------
_env_reg="${REGISTRY_NAME:-}"
_env_region="${AWS_DEFAULT_REGION:-}"
_env_base="${PACK_BASE_PATH:-}"
_env_pal_host="${PALETTE_HOST:-}"
_env_pal_name="${PALETTE_REGISTRY_NAME:-}"
_env_pal_type="${PALETTE_REGISTRY_TYPE:-}"
_env_pal_proj="${PALETTE_PROJECT_UID:-}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi
REGISTRY_NAME="${_env_reg:-${REGISTRY_NAME:-$DEF_REGISTRY_NAME}}"
AWS_DEFAULT_REGION="${_env_region:-${AWS_DEFAULT_REGION:-$DEF_REGION}}"
PACK_BASE_PATH="${_env_base:-${PACK_BASE_PATH:-$DEF_BASE_PATH}}"
PALETTE_HOST="${_env_pal_host:-${PALETTE_HOST:-$DEF_PALETTE_HOST}}"
PALETTE_REGISTRY_NAME="${_env_pal_name:-${PALETTE_REGISTRY_NAME:-}}"
PALETTE_REGISTRY_TYPE="${_env_pal_type:-${PALETTE_REGISTRY_TYPE:-$DEF_PALETTE_TYPE}}"
PALETTE_PROJECT_UID="${_env_pal_proj:-${PALETTE_PROJECT_UID:-}}"
PALETTE_API_KEY="${PALETTE_API_KEY:-}"   # secret: env/.env only

# ---------- parse args (CLI flags override everything) ----------
ASSUME_YES=0; LEAN=0; DO_SYNC=0; SYNC_ONLY=0; WAIT_SYNC=0; SYNC_TIMEOUT=600
PACK_DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--registry)   REGISTRY_NAME="${2:?--registry needs a value}"; shift 2;;
    --region)        AWS_DEFAULT_REGION="${2:?--region needs a value}"; shift 2;;
    -b|--base-path)  PACK_BASE_PATH="${2:?--base-path needs a value}"; shift 2;;
    --lean)          LEAN=1; shift;;
    -s|--sync)       DO_SYNC=1; shift;;
    --sync-only)     DO_SYNC=1; SYNC_ONLY=1; shift;;
    --wait)          WAIT_SYNC=1; shift;;
    --registry-name) PALETTE_REGISTRY_NAME="${2:?--registry-name needs a value}"; shift 2;;
    --registry-type) PALETTE_REGISTRY_TYPE="${2:?--registry-type needs a value}"; shift 2;;
    --project-uid)   PALETTE_PROJECT_UID="${2:?--project-uid needs a value}"; shift 2;;
    --palette-host)  PALETTE_HOST="${2:?--palette-host needs a value}"; shift 2;;
    --sync-timeout)  SYNC_TIMEOUT="${2:?--sync-timeout needs a value}"; shift 2;;
    -y|--yes)        ASSUME_YES=1; shift;;
    -h|--help)       usage; exit 0;;
    --)              shift; while [ $# -gt 0 ]; do PACK_DIRS+=("$1"); shift; done;;
    -*)              die "unknown option: $1 (try --help)";;
    *)               PACK_DIRS+=("$1"); shift;;
  esac
done
case "$PALETTE_REGISTRY_TYPE" in ecr|basic) ;; *) die "--registry-type must be 'ecr' or 'basic'";; esac

# ---------- preflight ----------
command -v jq >/dev/null 2>&1 || die "'jq' not found in PATH"
if [ "$SYNC_ONLY" -ne 1 ]; then
  for bin in aws oras tar mktemp; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH"
  done
fi
if [ "$DO_SYNC" -eq 1 ]; then
  command -v curl >/dev/null 2>&1 || die "'curl' not found in PATH (needed for --sync)"
  [ -n "$PALETTE_API_KEY" ]       || die "PALETTE_API_KEY is not set (put it in $ENV_FILE or the environment)"
  [ -n "$PALETTE_REGISTRY_NAME" ] || die "no Palette registry name — set --registry-name or PALETTE_REGISTRY_NAME"
fi

# ---------- scratch space (shared by packaging and the curl auth config) ----------
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ---------- resolve + validate packs (push path) ----------
names=(); versions=(); dirs=()
if [ "$SYNC_ONLY" -ne 1 ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    || die "aws sts get-caller-identity failed — check your AWS credentials/SSO session"
  [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "None" ] || die "could not determine AWS account id"
  REGISTRY_HOST="${ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
  REPO_ROOT="${REGISTRY_NAME}/${PACK_BASE_PATH}"

  [ ${#PACK_DIRS[@]} -eq 0 ] && PACK_DIRS=(".")
  for d in "${PACK_DIRS[@]}"; do
    [ -d "$d" ] || die "not a directory: $d"
    [ -f "$d/pack.json" ] || die "no pack.json in: $d"
    jq empty "$d/pack.json" 2>/dev/null || die "invalid JSON: $d/pack.json"
    n="$(jq -r '.name // empty' "$d/pack.json")"
    v="$(jq -r '.version // empty' "$d/pack.json")"
    [ -n "$n" ] && [ -n "$v" ] || die "pack.json in '$d' is missing name and/or version"
    abs="$(cd "$d" && pwd)"; base="$(basename "$abs")"
    [ "$base" = "$n-$v" ] || warn "directory '$base' != '$n-$v' — artifact root will be '$base'"
    names+=("$n"); versions+=("$v"); dirs+=("$abs")
  done
fi

# ---------- confirmation ----------
info ""
if [ "$SYNC_ONLY" -ne 1 ]; then
  info "Target registry : ${yellow}${REGISTRY_HOST}/${REPO_ROOT}${clear}"
  info "Packs to push   : ${#dirs[@]}"
  i=0; while [ $i -lt ${#dirs[@]} ]; do info "  - ${names[$i]}:${versions[$i]}"; i=$((i+1)); done
fi
if [ "$DO_SYNC" -eq 1 ]; then
  info "Palette sync    : ${yellow}${PALETTE_REGISTRY_NAME}${clear} (${PALETTE_REGISTRY_TYPE}) on ${PALETTE_HOST}${PALETTE_PROJECT_UID:+ [project ${PALETTE_PROJECT_UID}]}"
fi
if [ "$ASSUME_YES" -ne 1 ]; then
  if [ -t 0 ]; then
    printf 'Proceed? [y/N] '; read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) die "aborted by user";; esac
  else
    die "refusing to proceed without confirmation — pass --yes to run non-interactively"
  fi
fi

# ---------- push ----------
if [ "$SYNC_ONLY" -ne 1 ]; then
  info "Logging in to ${REGISTRY_HOST} ..."
  aws ecr get-login-password --region "$AWS_DEFAULT_REGION" \
    | oras login --username AWS --password-stdin "$REGISTRY_HOST" >/dev/null
  ok "Logged in."

  ensure_repo() {
    aws ecr describe-repositories --repository-names "$1" --region "$AWS_DEFAULT_REGION" >/dev/null 2>&1 \
      || aws ecr create-repository --repository-name "$1" --region "$AWS_DEFAULT_REGION" >/dev/null
  }
  ensure_repo "$REPO_ROOT"

  i=0
  while [ $i -lt ${#dirs[@]} ]; do
    n="${names[$i]}"; v="${versions[$i]}"; dir="${dirs[$i]}"
    base="$(basename "$dir")"; parent="$(dirname "$dir")"
    ref="${REGISTRY_HOST}/${REPO_ROOT}/${n}:${v}"

    info ""
    info "Packaging ${yellow}${n} v${v}${clear} ..."
    ensure_repo "${REPO_ROOT}/${n}"

    pkgdir="$TMPROOT/$n-$v"; mkdir -p "$pkgdir"
    tarfile="$pkgdir/$n-$v.tar.gz"
    if [ "$LEAN" -eq 1 ]; then
      ( cd "$parent" && find "$base" -type f -not -path "$base/charts/*/*" -print0 \
          | tar -czf "$tarfile" --null -T - )
    else
      ( cd "$parent" && tar -czf "$tarfile" "$base" )
    fi

    info "Pushing ${ref} ..."
    ( cd "$pkgdir" && oras push "$ref" "$n-$v.tar.gz" >/dev/null )
    if oras manifest fetch "$ref" >/dev/null 2>&1; then
      ok "Pushed & verified ${n} v${v}"
    else
      warn "pushed ${ref} but verification (manifest fetch) failed"
    fi
    i=$((i+1))
  done
  info ""
  ok "Done. Pushed ${#dirs[@]} pack(s) to ${REGISTRY_HOST}/${REPO_ROOT}"
fi

# ---------- Palette sync ----------
if [ "$DO_SYNC" -eq 1 ]; then
  # Keep the API key out of argv/ps by passing it via a curl config file (0600).
  PAL_CFG="$TMPROOT/palette.curl"
  ( umask 077; printf 'header = "apiKey: %s"\n' "$PALETTE_API_KEY" > "$PAL_CFG" )

  HTTP_CODE=""; HTTP_BODY=""
  palette_curl() {  # palette_curl METHOD PATH [extra curl args...]
    local method="$1" path="$2"; shift 2
    local url="https://${PALETTE_HOST}${path}"
    if [ -n "$PALETTE_PROJECT_UID" ]; then
      case "$url" in *\?*) url="${url}&ProjectUid=${PALETTE_PROJECT_UID}";;
                     *)    url="${url}?ProjectUid=${PALETTE_PROJECT_UID}";; esac
    fi
    local out
    out="$(curl -sS -m 60 -w $'\n%{http_code}' -X "$method" "$url" \
            --config "$PAL_CFG" -H 'Accept: application/json' "$@")" \
      || { warn "network error calling $method $path"; return 1; }
    HTTP_CODE="${out##*$'\n'}"; HTTP_BODY="${out%$'\n'*}"
  }

  info ""
  info "Resolving Palette registry ${yellow}${PALETTE_REGISTRY_NAME}${clear} ..."
  palette_curl GET /v1/registries/oci/summary || die "could not reach Palette at $PALETTE_HOST"
  [ "$HTTP_CODE" = "200" ] || die "listing OCI registries failed (HTTP $HTTP_CODE): $(printf '%s' "$HTTP_BODY" | jq -r '.message // .' 2>/dev/null | head -1)"

  matches="$(printf '%s' "$HTTP_BODY" | jq -c --arg n "$PALETTE_REGISTRY_NAME" '[.items[]? | select(.metadata.name==$n)]')"
  count="$(printf '%s' "$matches" | jq 'length')"
  case "$count" in
    1) ;;
    0) die "no OCI registry named '$PALETTE_REGISTRY_NAME' visible to this API key (check the name, --project-uid scope, and key permissions)";;
    *) die "$count OCI registries named '$PALETTE_REGISTRY_NAME' — disambiguate with --project-uid";;
  esac
  REG_UID="$(printf '%s' "$matches" | jq -r '.[0].metadata.uid')"
  [ -n "$REG_UID" ] && [ "$REG_UID" != "null" ] || die "could not extract the registry UID"
  # Trust the registry type reported by the API (falls back to the configured value).
  det_type="$(printf '%s' "$matches" | jq -r '.[0].spec.registryType // empty')"
  if [ -n "$det_type" ]; then
    case "$det_type" in ecr) PALETTE_REGISTRY_TYPE="ecr";; *) PALETTE_REGISTRY_TYPE="basic";; esac
  fi
  ok "Resolved '$PALETTE_REGISTRY_NAME' -> uid ${REG_UID} (type: ${PALETTE_REGISTRY_TYPE})"

  if [ "$PALETTE_REGISTRY_TYPE" = "ecr" ]; then
    sync_path="/v1/registries/oci/${REG_UID}/ecr/sync"
    status_path="/v1/registries/oci/${REG_UID}/ecr/sync/status"
  else
    sync_path="/v1/registries/oci/${REG_UID}/sync"
    status_path="/v1/registries/oci/${REG_UID}/sync/status"
  fi

  # Note the previous run time so --wait can detect the NEW run (status may
  # already read "Completed" from an earlier sync).
  prev_run=""
  if [ "$WAIT_SYNC" -eq 1 ] && palette_curl GET "$status_path" && [ "$HTTP_CODE" = "200" ]; then
    prev_run="$(printf '%s' "$HTTP_BODY" | jq -r '.lastRunTime // empty')"
  fi

  info "Triggering sync ..."
  palette_curl POST "$sync_path" || die "sync request failed"
  case "$HTTP_CODE" in
    200|202|204) ok "Sync triggered (HTTP $HTTP_CODE).";;
    *) die "sync failed (HTTP $HTTP_CODE): $(printf '%s' "$HTTP_BODY" | jq -r '.message // .' 2>/dev/null | head -1)";;
  esac

  if [ "$WAIT_SYNC" -eq 1 ]; then
    info "Waiting for sync to complete (timeout ${SYNC_TIMEOUT}s) ..."
    deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
    while :; do
      if palette_curl GET "$status_path" && [ "$HTTP_CODE" = "200" ]; then
        st="$(printf '%s' "$HTTP_BODY" | jq -r '.status // empty')"
        run="$(printf '%s' "$HTTP_BODY" | jq -r '.lastRunTime // empty')"
        info "  status: ${st:-unknown}${run:+ (lastRun ${run})}"
        # consider it done only once a NEW run has finished
        if [ "$run" != "$prev_run" ]; then
          case "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" in
            completed|active|synced|success*) ok "Sync completed (status: $st)"; break;;
            failed|error*)                    die "sync reported status: $st";;
          esac
        fi
      fi
      [ "$(date +%s)" -ge "$deadline" ] && { warn "timed out after ${SYNC_TIMEOUT}s (sync may still be running)"; break; }
      sleep 10
    done
  fi
fi
