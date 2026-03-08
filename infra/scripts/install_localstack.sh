#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalacion de LocalStack (S3 + Secrets Manager) ==="

# -----------------------------
# Configuracion dinamica de rutas
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../../values/localstack-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/values/localstack-values.yaml"
fi

# kubeconfig por defecto en k3s
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Parametros
LOCALSTACK_NAMESPACE="${LOCALSTACK_NAMESPACE:-localstack}"
LOCALSTACK_RELEASE_NAME="${LOCALSTACK_RELEASE_NAME:-localstack}"
LOCALSTACK_CHART="${LOCALSTACK_CHART:-localstack/localstack}"
LOCALSTACK_HELM_REPO_NAME="${LOCALSTACK_HELM_REPO_NAME:-localstack}"
LOCALSTACK_HELM_REPO_URL="${LOCALSTACK_HELM_REPO_URL:-https://helm.localstack.cloud}"
LOCALSTACK_NODEPORT="${LOCALSTACK_NODEPORT:-31566}"
LOCALSTACK_SERVICES="${LOCALSTACK_SERVICES:-s3,secretsmanager}"

# Variables AWS esperadas desde GitHub Secrets
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY:-}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${AWS_SECRETE_KEY:-}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"

# Helpers
run_privileged() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        return 1
    fi
}

gh_group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "[INFO] $*"; }
gh_group_end() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || echo ""; }

install_aws_cli() {
    if command -v aws >/dev/null 2>&1; then
        echo "[INFO] AWS CLI ya esta instalado en: $(command -v aws)"
        aws --version || true
        return 0
    fi

    echo "[INFO] AWS CLI no encontrado. Instalando..."
    if command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update -y
        run_privileged apt-get install -y awscli
    elif command -v dnf >/dev/null 2>&1; then
        run_privileged dnf install -y awscli
    elif command -v yum >/dev/null 2>&1; then
        run_privileged yum install -y awscli
    else
        TMP_DIR="$(mktemp -d)"
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMP_DIR/awscliv2.zip"
        command -v unzip >/dev/null 2>&1 || { echo "[ERROR] unzip no encontrado para instalar AWS CLI"; return 1; }
        unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
        run_privileged "$TMP_DIR/aws/install" --update
        rm -rf "$TMP_DIR"
    fi

    command -v aws >/dev/null 2>&1 || { echo "[ERROR] AWS CLI no pudo instalarse"; return 1; }
    echo "[INFO] AWS CLI instalado en: $(command -v aws)"
    aws --version || true
}

# -----------------------------
# Pre-chequeos
# -----------------------------
gh_group "Pre-chequeos"

if [ ! -f "$VALUES_FILE" ]; then
    echo "[ERROR] No se encontro el archivo de values en: $VALUES_FILE"
    exit 1
fi

echo "[INFO] Usando values: $VALUES_FILE"

for cmd in kubectl helm curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_DEFAULT_REGION" ]; then
    echo "[ERROR] Faltan variables AWS. Requeridas: AWS_ACCESS_KEY (o AWS_ACCESS_KEY_ID), AWS_SECRETE_KEY (o AWS_SECRET_ACCESS_KEY), AWS_REGION (o AWS_DEFAULT_REGION)."
    exit 1
fi

if [ ! -r "$KUBECONFIG" ]; then
    echo "[ERROR] No se puede leer KUBECONFIG: $KUBECONFIG"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] No hay conectividad con Kubernetes"
    exit 1
fi

echo "[INFO] Verificando AWS CLI..."
install_aws_cli

# Configuracion AWS CLI para uso local en el runner
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set region "$AWS_DEFAULT_REGION"

gh_group_end

# -----------------------------
# Install/Upgrade de LocalStack
# -----------------------------
gh_group "Instalacion LocalStack"

kubectl create namespace "$LOCALSTACK_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Actualizando repo Helm $LOCALSTACK_HELM_REPO_NAME..."
helm repo add "$LOCALSTACK_HELM_REPO_NAME" "$LOCALSTACK_HELM_REPO_URL" --force-update
helm repo update "$LOCALSTACK_HELM_REPO_NAME"

# Secret con credenciales AWS disponibles para workloads que lo necesiten
kubectl -n "$LOCALSTACK_NAMESPACE" create secret generic localstack-aws-credentials \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Helm upgrade/install de LocalStack..."
helm upgrade --install "$LOCALSTACK_RELEASE_NAME" "$LOCALSTACK_CHART" \
    --namespace "$LOCALSTACK_NAMESPACE" \
    -f "$VALUES_FILE" \
    --wait \
    --timeout 300s

gh_group_end

# -----------------------------
# Forzar servicios y NodePort fijo
# -----------------------------
gh_group "Ajustes de runtime"

DEPLOYMENT_NAME="$(kubectl get deploy -n "$LOCALSTACK_NAMESPACE" -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}')"
SERVICE_NAME="$(kubectl get svc -n "$LOCALSTACK_NAMESPACE" -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}')"

if [ -z "$DEPLOYMENT_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "[ERROR] No se localizaron deployment/service de LocalStack"
    exit 1
fi

# Garantiza que LocalStack arranca solo con los servicios deseados
kubectl set env deployment/"$DEPLOYMENT_NAME" -n "$LOCALSTACK_NAMESPACE" SERVICES="$LOCALSTACK_SERVICES" AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"

# Fija siempre el mismo NodePort para el edge service (4566)
kubectl patch svc "$SERVICE_NAME" -n "$LOCALSTACK_NAMESPACE" --type merge -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":4566,\"targetPort\":4566,\"protocol\":\"TCP\",\"nodePort\":${LOCALSTACK_NODEPORT}}]}}"

kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$LOCALSTACK_NAMESPACE" --timeout=180s

gh_group_end

# -----------------------------
# Validacion final
# -----------------------------
gh_group "Validacion"

kubectl get pods -n "$LOCALSTACK_NAMESPACE" -o wide
kubectl get svc -n "$LOCALSTACK_NAMESPACE"

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
echo "[SUCCESS] LocalStack listo"
echo "[INFO] Endpoint Edge: http://${NODE_IP}:${LOCALSTACK_NODEPORT}"
echo "[INFO] Servicios activos: ${LOCALSTACK_SERVICES}"

gh_group_end
