#!/bin/bash
# Temporary build box on Hetzner Cloud (PLAN-fast-build.md, Phase E2 and G).
# Talks to the Cloud API directly (https://docs.hetzner.cloud/reference/cloud),
# so no hcloud CLI is needed. Needs curl, jq and ssh-keygen.
#
# The API token comes from HETZNER_API_KEY. It is passed to curl through a
# mode-600 header file, never on the command line.
#
# Every box gets the label purpose=museum-build. Local state (server JSON, an
# SSH config entry, known_hosts) lives in $STATE_DIR, outside the repo, because
# Hetzner reuses IPs.
#
# Usage:
#   tools/fastbuild/provision/hetzner.sh types [prefix]     # read-only: specs + hourly price
#   tools/fastbuild/provision/hetzner.sh create [--name N] [--type T] [--location L]
#                                               [--image I] [--user-data FILE]
#   tools/fastbuild/provision/hetzner.sh list               # boxes labelled purpose=museum-build
#   tools/fastbuild/provision/hetzner.sh status [--name N]
#   tools/fastbuild/provision/hetzner.sh delete [--name N] [--yes]
#
# After create:  ssh -F "$STATE_DIR/<name>.ssh_config" <name>
set -euo pipefail

API="https://api.hetzner.cloud/v1"
LABEL="purpose=museum-build"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/museum-build}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/museum_build_ed25519}"
NAME="museum-build"
TYPE="ccx63"
LOCATION=""
IMAGE="ubuntu-24.04"
USER_DATA=""
YES=0

die() { echo "hetzner.sh: $*" >&2; exit 1; }

[ -n "${HETZNER_API_KEY:-}" ] || die "HETZNER_API_KEY is not set"
command -v jq >/dev/null || die "jq not found"

HDR="$(mktemp)"
trap 'rm -f "$HDR"' EXIT
chmod 600 "$HDR"
printf 'Authorization: Bearer %s\n' "$HETZNER_API_KEY" > "$HDR"

# api METHOD PATH [JSON]: prints the response body; fails on HTTP >= 400 with
# the API's error code and message.
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" -H @"$HDR" \
      -H 'Content-Type: application/json' --data-binary "$body" "$API$path")"
  else
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" -H @"$HDR" "$API$path")"
  fi
  if [ "$code" -ge 400 ]; then
    echo "hetzner.sh: $method $path -> HTTP $code: $(jq -r '.error | "\(.code): \(.message)"' "$out" 2>/dev/null || cat "$out")" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

# wait_action ID: polls until the action leaves "running".
wait_action() {
  local id="$1" st
  while :; do
    st="$(api GET "/actions/$id" | jq -r '.action.status')"
    case "$st" in
      success) return 0 ;;
      error) api GET "/actions/$id" | jq -r '.action.error' >&2; return 1 ;;
    esac
    sleep 3
  done
}

server_json() {
  api GET "/servers?name=$NAME" | jq -e '.servers[0] // empty' \
    || die "no server named $NAME"
}

# Uploads $SSH_KEY.pub unless the project already has a key with the same
# fingerprint; prints the key's id.
ensure_ssh_key() {
  if [ ! -f "$SSH_KEY.pub" ]; then
    ssh-keygen -t ed25519 -N '' -C "museum-build" -f "$SSH_KEY" -q
  fi
  local fp id
  fp="$(ssh-keygen -l -E md5 -f "$SSH_KEY.pub" | awk '{print $2}' | sed 's/^MD5://')"
  id="$(api GET "/ssh_keys?fingerprint=$fp" | jq -r '.ssh_keys[0].id // empty')"
  if [ -z "$id" ]; then
    id="$(api POST /ssh_keys "$(jq -n --arg n "museum-build-$(date +%Y%m%d%H%M%S)" \
      --arg k "$(cat "$SSH_KEY.pub")" '{name: $n, public_key: $k, labels: {purpose: "museum-build"}}')" \
      | jq -r '.ssh_key.id')"
  fi
  echo "$id"
}

write_ssh_config() {
  local ip="$1"
  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/$NAME.ssh_config" <<EOF
Host $NAME
    HostName $ip
    User root
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    UserKnownHostsFile $STATE_DIR/$NAME.known_hosts
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
EOF
  : > "$STATE_DIR/$NAME.known_hosts"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --user-data) USER_DATA="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    *) if [ "$cmd" = types ]; then PREFIX="$1"; shift; else die "unknown argument $1"; fi ;;
  esac
done

case "$cmd" in
  types)
    api GET "/server_types?per_page=50" | jq -r --arg p "${PREFIX:-}" '
      .server_types[] | select(.deprecated | not) | select(.name | startswith($p))
      | "\(.name)\t\(.cores) \(.cpu_type) vCPU\t\(.memory) GB\t\(.disk) GB\t"
        + ([.prices[] | "\(.location) €\(.price_hourly.gross | tonumber * 100 | round / 100)/h"] | join(", "))'
    ;;

  create)
    if api GET "/servers?name=$NAME" | jq -e '.servers | length > 0' >/dev/null; then
      die "a server named $NAME already exists (status, or delete it first)"
    fi
    key_id="$(ensure_ssh_key)"
    body="$(jq -n --arg n "$NAME" --arg t "$TYPE" --arg i "$IMAGE" --arg l "$LOCATION" \
      --argjson k "$key_id" '
      {name: $n, server_type: $t, image: $i, ssh_keys: [$k],
       labels: {purpose: "museum-build"}, start_after_create: true,
       public_net: {enable_ipv4: true, enable_ipv6: true}}
      + (if $l != "" then {location: $l} else {} end)')"
    if [ -n "$USER_DATA" ]; then
      [ -f "$USER_DATA" ] || die "user data file $USER_DATA not found"
      body="$(jq --rawfile u "$USER_DATA" '. + {user_data: $u}' <<<"$body")"
    fi
    resp="$(api POST /servers "$body")"
    ip="$(jq -r '.server.public_net.ipv4.ip' <<<"$resp")"
    echo "created $NAME ($TYPE, $(jq -r '.server.datacenter.name' <<<"$resp")) at $ip; waiting for it to start"
    wait_action "$(jq -r '.action.id' <<<"$resp")"
    for a in $(jq -r '.next_actions[].id' <<<"$resp"); do wait_action "$a"; done
    mkdir -p "$STATE_DIR"
    server_json > "$STATE_DIR/$NAME.json"
    write_ssh_config "$ip"
    echo "running. ssh -F $STATE_DIR/$NAME.ssh_config $NAME"
    echo "billing runs until: $0 delete --name $NAME"
    ;;

  list)
    api GET "/servers?label_selector=$LABEL" | jq -r '
      .servers[] | "\(.name)\t\(.server_type.name)\t\(.status)\t\(.public_net.ipv4.ip)\t\(.datacenter.name)\tcreated \(.created)"'
    ;;

  status)
    server_json | jq -r '"\(.name)\t\(.server_type.name)\t\(.status)\t\(.public_net.ipv4.ip)\t\(.datacenter.name)\tcreated \(.created)"'
    ;;

  delete)
    s="$(server_json)"
    jq -e '.labels.purpose == "museum-build"' <<<"$s" >/dev/null \
      || die "$NAME has no label $LABEL; refusing to delete it"
    if [ "$YES" -ne 1 ]; then
      read -r -p "Delete $NAME ($(jq -r '.public_net.ipv4.ip' <<<"$s")) and its disk? Type the name: " ans
      [ "$ans" = "$NAME" ] || die "not deleted"
    fi
    wait_action "$(api DELETE "/servers/$(jq -r '.id' <<<"$s")" | jq -r '.action.id')"
    for k in $(api GET "/ssh_keys?label_selector=$LABEL" | jq -r '.ssh_keys[].id'); do
      api DELETE "/ssh_keys/$k" >/dev/null
    done
    rm -f "$STATE_DIR/$NAME".{json,ssh_config,known_hosts}
    echo "deleted $NAME and the museum-build SSH keys"
    ;;

  *)
    sed -n '2,22p' "$0"; exit 1 ;;
esac
