#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalacion de Trivy Operator ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../values/trivy-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/infra/values/trivy-values.yaml"
fi

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

TRIVY_NAMESPACE="${TRIVY_NAMESPACE:-trivy-system}"
TRIVY_RELEASE_NAME="${TRIVY_RELEASE_NAME:-trivy-operator}"
TRIVY_HELM_REPO_NAME="${TRIVY_HELM_REPO_NAME:-aquasecurity}"
TRIVY_HELM_REPO_URL="${TRIVY_HELM_REPO_URL:-https://aquasecurity.github.io/helm-charts}"
TRIVY_HELM_CHART="${TRIVY_HELM_CHART:-aquasecurity/trivy-operator}"

gh_group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "[INFO] $*"; }
gh_group_end() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || echo ""; }

gh_group "Pre-chequeos"

for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

if [ ! -f "$VALUES_FILE" ]; then
    echo "[ERROR] No se encontro el archivo de values en: $VALUES_FILE"
    exit 1
fi

echo "[INFO] Usando values: $VALUES_FILE"

if [ ! -r "$KUBECONFIG" ]; then
    echo "[ERROR] No se puede leer KUBECONFIG: $KUBECONFIG"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] No hay conectividad con Kubernetes"
    exit 1
fi

gh_group_end

gh_group "Verificar si ya existe Trivy Operator"

if helm status "$TRIVY_RELEASE_NAME" -n "$TRIVY_NAMESPACE" >/dev/null 2>&1; then
    echo "[INFO] Release '$TRIVY_RELEASE_NAME' ya existe en namespace '$TRIVY_NAMESPACE'."
    echo "[INFO] No se realiza instalacion."
    kubectl -n "$TRIVY_NAMESPACE" get deploy -l app.kubernetes.io/instance="$TRIVY_RELEASE_NAME" -o wide || true
    gh_group_end
    exit 0
fi

if kubectl -n "$TRIVY_NAMESPACE" get deploy trivy-operator >/dev/null 2>&1; then
    echo "[INFO] Deployment 'trivy-operator' ya existe en namespace '$TRIVY_NAMESPACE'."
    echo "[INFO] No se realiza instalacion."
    kubectl -n "$TRIVY_NAMESPACE" get deploy trivy-operator -o wide
    gh_group_end
    exit 0
fi

gh_group_end

gh_group "Instalacion Trivy Operator"

kubectl create namespace "$TRIVY_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm repo add "$TRIVY_HELM_REPO_NAME" "$TRIVY_HELM_REPO_URL" --force-update
helm repo update "$TRIVY_HELM_REPO_NAME"

helm upgrade --install "$TRIVY_RELEASE_NAME" "$TRIVY_HELM_CHART" \
  --namespace "$TRIVY_NAMESPACE" \
  -f "$VALUES_FILE" \
  --wait \
  --timeout 300s

gh_group_end

gh_group "Validacion"
kubectl -n "$TRIVY_NAMESPACE" rollout status deployment/trivy-operator --timeout=180s
kubectl -n "$TRIVY_NAMESPACE" get pods -l app.kubernetes.io/instance="$TRIVY_RELEASE_NAME" -o wide

if kubectl get crd vulnerabilityreports.aquasecurity.github.io >/dev/null 2>&1; then
    echo "[INFO] CRD vulnerabilityreports.aquasecurity.github.io disponible"
else
    echo "[ERROR] No se encontro el CRD vulnerabilityreports.aquasecurity.github.io"
    exit 1
fi
gh_group_end

echo "[SUCCESS] Trivy Operator instalado correctamente"
