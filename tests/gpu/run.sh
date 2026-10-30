#!/usr/bin/env bash
#
# GPU workloads on the NVKE cluster, one after another (each takes the whole
# GPU). Every test is a Job that fails when its check fails; it is deleted
# afterwards. First runs pull multi-GB images.
#
#   tests/gpu/run.sh               all tests
#   tests/gpu/run.sh pytorch       only files matching "pytorch"
#   KUBECONFIG=other.yaml tests/gpu/run.sh
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/nvke-mgmt.yaml}"
NAMESPACE=nvke-gpu-tests
TIMEOUT="${TIMEOUT:-900}"          # seconds per test
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

kubectl apply -f "$HERE/00-namespace.yaml" >/dev/null

results=()
failed=0
for file in "$HERE"/0[1-9]-*.yaml "$HERE"/[1-9][0-9]-*.yaml; do
  [[ -e $file ]] || continue
  [[ -n ${1:-} && $file != *"$1"* ]] && continue
  name=$(basename "$file" .yaml)
  job=$(kubectl apply -f "$file" -o name | grep '^job' | cut -d/ -f2)
  printf '\n==> %s\n' "$name"

  start=$SECONDS
  status=TIMEOUT
  while (( SECONDS - start < TIMEOUT )); do
    s=$(kubectl -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}')
    [[ $s == 1/* ]] && { status=PASS; break; }
    [[ $s == */1 ]] && { status=FAIL; break; }
    sleep 5
  done
  took=$((SECONDS - start))

  kubectl -n "$NAMESPACE" logs "job/$job" --tail=6 2>/dev/null | sed 's/^/    /'
  if [[ $status != PASS ]]; then
    failed=1
    kubectl -n "$NAMESPACE" get pods -l "job-name=$job" -o wide 2>/dev/null | sed 's/^/    /'
  fi
  printf '    %s (%ss)\n' "$status" "$took"
  results+=("$(printf '%-28s %-8s %5ss' "$name" "$status" "$took")")

  kubectl delete -f "$file" --wait=true --timeout=120s >/dev/null 2>&1
done

printf '\n==> summary\n'
printf '    %s\n' "${results[@]}"
exit "$failed"
