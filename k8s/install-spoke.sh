#!/bin/bash
# P3: regional spoke gateway stack for one PoC cluster.
# Installs pinned CRDs + Envoy Gateway + Envoy AI Gateway (llm-d v1.0.0 provider path,
# docs/infrastructure/gateway/envoy-ai-gateway.md @ llm-d release-1.0).
# Usage: ./install-spoke.sh <kubectl-context>
set -euo pipefail

CTX="${1:?usage: install-spoke.sh <kubectl-context>}"
K="kubectl --context ${CTX}"

# helm's OCI client honors docker's credsStore; docker-credential-desktop is not
# on PATH in this shell. Public charts need no auth — point helm at an empty
# docker config so it skips the credential helper entirely.
export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"
if [ ! -s "${DOCKER_CONFIG}/config.json" ]; then
  echo '{}' > "${DOCKER_CONFIG}/config.json"
fi

# Pinned (versions.lock)
GATEWAY_API_VERSION=v1.6.2
GAIE_VERSION=v1.6.2
ENVOY_GATEWAY_VERSION=v1.8.1
ENVOY_AI_GATEWAY_VERSION=v0.7.0

echo "==> [${CTX}] Gateway API ${GATEWAY_API_VERSION} + GAIE ${GAIE_VERSION} CRDs"
$K apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
$K apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"

echo "==> [${CTX}] Envoy Gateway CRDs ${ENVOY_GATEWAY_VERSION}"
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | grep -v '^Pulled:' | grep -v '^Digest:' | $K apply --server-side -f -

echo "==> [${CTX}] Envoy Gateway ${ENVOY_GATEWAY_VERSION} (AI-Gateway integration + InferencePool add-on)"
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --kube-context "${CTX}" \
  --namespace envoy-gateway-system \
  --create-namespace \
  --skip-crds \
  -f "https://raw.githubusercontent.com/envoyproxy/ai-gateway/${ENVOY_AI_GATEWAY_VERSION}/manifests/envoy-gateway-values.yaml" \
  -f "https://raw.githubusercontent.com/envoyproxy/ai-gateway/${ENVOY_AI_GATEWAY_VERSION}/examples/inference-pool/envoy-gateway-values-addon.yaml"

echo "==> [${CTX}] InferencePool watch RBAC for Envoy Gateway"
$K apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: envoy-gateway-inference-access
rules:
- apiGroups: ["inference.networking.k8s.io"]
  resources: ["inferencepools"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: envoy-gateway-inference-access
subjects:
- kind: ServiceAccount
  name: envoy-gateway
  namespace: envoy-gateway-system
roleRef:
  kind: ClusterRole
  name: envoy-gateway-inference-access
  apiGroup: rbac.authorization.k8s.io
EOF

$K wait --timeout=3m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "==> [${CTX}] Envoy AI Gateway ${ENVOY_AI_GATEWAY_VERSION} CRDs + controller"
helm upgrade -i envoy-ai-gateway-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version "${ENVOY_AI_GATEWAY_VERSION}" \
  --kube-context "${CTX}" \
  --namespace envoy-ai-gateway-system \
  --create-namespace
helm upgrade -i envoy-ai-gateway oci://docker.io/envoyproxy/ai-gateway-helm \
  --version "${ENVOY_AI_GATEWAY_VERSION}" \
  --kube-context "${CTX}" \
  --namespace envoy-ai-gateway-system \
  --create-namespace
$K wait --timeout=3m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "==> [${CTX}] GatewayClass envoy-ai-gateway"
$K apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-ai-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

echo "==> [${CTX}] spoke gateway stack complete"
