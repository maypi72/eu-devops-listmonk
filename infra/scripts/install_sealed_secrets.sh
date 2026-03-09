#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalacion de Sealed Secrets ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../values/sealed-secrets-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/infra/values/sealed-secrets-values.yaml"
fi

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-kube-system}"
SEALED_SECRETS_RELEASE_NAME="${SEALED_SECRETS_RELEASE_NAME:-sealed-secrets}"
SEALED_SECRETS_HELM_REPO_NAME="${SEALED_SECRETS_HELM_REPO_NAME:-bitnami}"
SEALED_SECRETS_HELM_REPO_URL="${SEALED_SECRETS_HELM_REPO_URL:-https://charts.bitnami.com/bitnami}"
SEALED_SECRETS_CHART="${SEALED_SECRETS_CHART:-bitnami/sealed-secrets}"

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

gh_group "Verificar si ya existe Sealed Secrets"

if helm status "$SEALED_SECRETS_RELEASE_NAME" -n "$SEALED_SECRETS_NAMESPACE" >/dev/null 2>&1; then
    echo "[INFO] Release '$SEALED_SECRETS_RELEASE_NAME' ya existe en namespace '$SEALED_SECRETS_NAMESPACE'."
    echo "[INFO] No se realiza instalacion."
    kubectl -n "$SEALED_SECRETS_NAMESPACE" get deploy -l app.kubernetes.io/instance="$SEALED_SECRETS_RELEASE_NAME" -o wide || true
    gh_group_end
    exit 0
fi

if kubectl -n "$SEALED_SECRETS_NAMESPACE" get deploy sealed-secrets >/dev/null 2>&1; then
    echo "[INFO] Deployment 'sealed-secrets' ya existe en namespace '$SEALED_SECRETS_NAMESPACE'."
    echo "[INFO] No se realiza instalacion."
    kubectl -n "$SEALED_SECRETS_NAMESPACE" get deploy sealed-secrets -o wide
    gh_group_end
    exit 0
fi

gh_group_end

gh_group "Instalacion Sealed Secrets"

kubectl create namespace "$SEALED_SECRETS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm repo add "$SEALED_SECRETS_HELM_REPO_NAME" "$SEALED_SECRETS_HELM_REPO_URL" --force-update
helm repo update "$SEALED_SECRETS_HELM_REPO_NAME"

helm upgrade --install "$SEALED_SECRETS_RELEASE_NAME" "$SEALED_SECRETS_CHART" \
  --namespace "$SEALED_SECRETS_NAMESPACE" \
    -f "$VALUES_FILE" \
  --wait \
  --timeout 300s

gh_group_end

gh_group "Validacion"
kubectl -n "$SEALED_SECRETS_NAMESPACE" rollout status deployment/sealed-secrets --timeout=180s
kubectl -n "$SEALED_SECRETS_NAMESPACE" get pods -l app.kubernetes.io/instance="$SEALED_SECRETS_RELEASE_NAME" -o wide

if kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then
    echo "[INFO] CRD sealedsecrets.bitnami.com disponible"
else
    echo "[ERROR] No se encontro el CRD sealedsecrets.bitnami.com"
    exit 1
fi
gh_group_end

echo "[SUCCESS] Sealed Secrets instalado correctamente"
