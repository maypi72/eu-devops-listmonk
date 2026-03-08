#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalacion de cert-manager (Self-Signed) ==="

# -----------------------------
# Configuracion dinamica de rutas
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../../values/cert-manager-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/values/cert-manager-values.yaml"
fi

# kubeconfig por defecto en k3s
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Parametros
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-1.14.5}"
HELM_REPO_NAME="jetstack"
HELM_REPO_URL="https://charts.jetstack.io"
RELEASE_NAME="cert-manager"

APP_NAMESPACE="${APP_NAMESPACE:-listmonk}"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-listmonk.local}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-listmonk-local-tls}"
SELF_SIGNED_ISSUER_NAME="${SELF_SIGNED_ISSUER_NAME:-selfsigned-local}"
CA_ISSUER_NAME="${CA_ISSUER_NAME:-ca-local}"
CA_CERT_NAME="${CA_CERT_NAME:-local-root-ca}"
APP_CERT_NAME="${APP_CERT_NAME:-listmonk-local-wildcard}"

# Helpers para GitHub Actions
gh_group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "[INFO] $*"; }
gh_group_end() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || echo ""; }

# -----------------------------
# Pre-chequeos
# -----------------------------
gh_group "Pre-chequeos"

if [ ! -f "$VALUES_FILE" ]; then
    echo "[ERROR] No se encontro el archivo de values en: $VALUES_FILE"
    exit 1
fi

echo "[INFO] Usando values: $VALUES_FILE"

for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

if [ ! -r "$KUBECONFIG" ]; then
    echo "[ERROR] No se puede leer KUBECONFIG: $KUBECONFIG"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] El runner no puede conectar con Kubernetes"
    exit 1
fi
gh_group_end

# -----------------------------
# Instalacion cert-manager
# -----------------------------
gh_group "Instalacion cert-manager"

kubectl create namespace "$CERT_MANAGER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Actualizando repo Helm $HELM_REPO_NAME..."
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update
helm repo update "$HELM_REPO_NAME"

echo "[INFO] Helm upgrade/install de cert-manager..."
helm upgrade --install "$RELEASE_NAME" "$HELM_REPO_NAME/cert-manager" \
    --namespace "$CERT_MANAGER_NAMESPACE" \
    --version "$CERT_MANAGER_CHART_VERSION" \
    -f "$VALUES_FILE" \
    --wait \
    --timeout 300s

gh_group_end

# -----------------------------
# Emision Self-Signed para listmonk.local
# -----------------------------
gh_group "Configuracion de Issuers y Certificate"

kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${SELF_SIGNED_ISSUER_NAME}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CA_CERT_NAME}
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  isCA: true
  commonName: "${LOCAL_DOMAIN} Local Root CA"
  secretName: ${CA_CERT_NAME}-secret
  duration: 87600h
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: ${SELF_SIGNED_ISSUER_NAME}
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CA_ISSUER_NAME}
spec:
  ca:
    secretName: ${CA_CERT_NAME}-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${APP_CERT_NAME}
  namespace: ${APP_NAMESPACE}
spec:
  secretName: ${TLS_SECRET_NAME}
  duration: 2160h
  renewBefore: 360h
  dnsNames:
    - ${LOCAL_DOMAIN}
    - '*.${LOCAL_DOMAIN}'
  issuerRef:
    name: ${CA_ISSUER_NAME}
    kind: ClusterIssuer
EOF

echo "[INFO] Esperando certificate ${APP_CERT_NAME} en namespace ${APP_NAMESPACE}..."
kubectl wait certificate/${APP_CERT_NAME} -n "${APP_NAMESPACE}" --for=condition=Ready=True --timeout=180s

echo "[INFO] Secret TLS generado: ${APP_NAMESPACE}/${TLS_SECRET_NAME}"
kubectl get secret "${TLS_SECRET_NAME}" -n "${APP_NAMESPACE}" >/dev/null

gh_group_end

echo "[SUCCESS] cert-manager instalado y certificado local emitido."
echo "[INFO] ClusterIssuer para Ingress: ${CA_ISSUER_NAME}"
echo "[INFO] TLS Secret para app: ${TLS_SECRET_NAME} (namespace ${APP_NAMESPACE})"
