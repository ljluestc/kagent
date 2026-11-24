#!/usr/bin/env bash
# Tests how scripts/kind/setup-kind.sh makes the API server reachable, against
# fake docker, kind, and kubectl commands that log their arguments.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake_bin="$work/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/kind" <<'EOF'
#!/usr/bin/env bash
echo "kind $*" >>"$CALLS"
if [ "$1 $2" = "get clusters" ] && [ "$CLUSTER_EXISTS" = true ]; then echo kagent; fi
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS"
case "$*" in
  *State.Running*) echo true ;;
  "inspect "*devcontainer-id) echo "$SELF_NETWORK" ;;
  "inspect "*) echo '{}' ;;
esac
EOF
cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
cat >/dev/null
EOF
chmod +x "$fake_bin"/*

export CALLS="$work/calls"
join="docker network connect kind devcontainer-id"
export_config="kind export kubeconfig --name kagent --internal"

# run <internal> <cluster exists> <this container's kind network, as JSON>
run() {
  : >"$CALLS"
  (cd "$root" && PATH="$fake_bin:$PATH" HOSTNAME=devcontainer-id CONTAINER_RUNTIME=docker KIND_CLUSTER_NAME=kagent \
    KIND_INTERNAL_KUBECONFIG="$1" CLUSTER_EXISTS="$2" SELF_NETWORK="$3" \
    bash scripts/kind/setup-kind.sh >/dev/null)
}
fail() { echo "FAIL: $1"; cat "$CALLS"; exit 1; }
called() { grep -qxF -- "$1" "$CALLS"; }
line() { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }

run "" false null
if called "$join" || called "$export_config"; then fail "host setup must not change"; fi

run true false null
called "$join" || fail "a dev container must join the kind network"
called "$export_config" || fail "a dev container must use the internal kubeconfig"
[ "$(line "kind create cluster")" -lt "$(line "$join")" ] || fail "the kind network must exist before joining"
[ "$(line "$export_config")" -lt "$(line "kubectl ")" ] || fail "the kubeconfig must be set before kubectl runs"

run true true null
if [ -n "$(line "kind create cluster" || true)" ]; then fail "an existing cluster must be reused"; fi
called "$join" || fail "a rebuilt dev container must join the kind network"
called "$export_config" || fail "a rebuilt dev container must get a kubeconfig"

run true true '{}'
if called "$join"; then fail "a joined dev container must not join again"; fi
called "$export_config" || fail "a joined dev container must use the internal kubeconfig"

echo "PASS"
