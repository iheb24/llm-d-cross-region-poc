#!/bin/bash
# boundary-check: fail if tracked files expose unreviewed public surface.
# Allowlist entries must carry a comment on the same line:
#   # boundary-ok: <reason + link to docs/risk-note-public-gateways.md>
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

fail=0

check() {
  local pattern="$1" what="$2"
  while IFS= read -r line; do
    # skip pure comment lines; markers live as trailing comments on value lines
    content="${line#*:}"
    case "$content" in
      *:*)
        value="${content#*:}"
        ;;
      *) value="$content" ;;
    esac
    [[ "$value" =~ ^[[:space:]]*# ]] && continue
    case "$line" in
      *boundary-ok*) ;; # allowlisted with a reason
      *) echo "BOUNDARY: unreviewed $what -> $line"; fail=1 ;;
    esac
  done < <(git grep -n -I "$pattern" -- '*.yaml' '*.yml' '*.tf' 2>/dev/null | grep -v '^scripts/check-boundary.sh' || true)
}

check 'type: LoadBalancer' 'LoadBalancer Service'
check 'loadBalancerIP' 'static public LB IP'
check '0.0.0.0/0' 'open-to-world CIDR'

if [ "$fail" -ne 0 ]; then
  echo
  echo "Public-exposure guard failed. Add '# boundary-ok: <reason>' (and a risk note) or remove the exposure."
  exit 1
fi
