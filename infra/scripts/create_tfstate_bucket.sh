#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Crear bucket S3 para Terraform state en LocalStack ==="

# kubeconfig por defecto en k3s
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Parametros configurables
LOCALSTACK_NAMESPACE="${LOCALSTACK_NAMESPACE:-localstack}"
LOCALSTACK_RELEASE_NAME="${LOCALSTACK_RELEASE_NAME:-localstack}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-terraform-tfstate}"

# Variables AWS esperadas desde GitHub Secrets
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY:-}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${AWS_SECRETE_KEY:-}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"

# Helpers para GitHub Actions
gh_group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "[INFO] $*"; }
gh_group_end() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || echo ""; }

# -----------------------------
# Pre-chequeos
# -----------------------------
gh_group "Pre-chequeos"

for cmd in kubectl aws curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_DEFAULT_REGION" ]; then
    echo "[ERROR] Faltan variables AWS. Requeridas: AWS_ACCESS_KEY (o AWS_ACCESS_KEY_ID), AWS_SECRETE_KEY (o AWS_SECRET_ACCESS_KEY), AWS_REGION (o AWS_DEFAULT_REGION)."
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] No hay conectividad con Kubernetes"
    exit 1
fi

gh_group_end

# -----------------------------
# Verificar LocalStack levantado
# -----------------------------
gh_group "Verificar LocalStack"

if ! kubectl get ns "$LOCALSTACK_NAMESPACE" >/dev/null 2>&1; then
    echo "[ERROR] Namespace '$LOCALSTACK_NAMESPACE' no existe. Debes desplegar LocalStack primero."
    exit 1
fi

# Espera a que el deployment exista y este listo
if ! kubectl -n "$LOCALSTACK_NAMESPACE" get deploy -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" >/dev/null 2>&1; then
    echo "[ERROR] No se encontro deployment de LocalStack con release '$LOCALSTACK_RELEASE_NAME'"
    exit 1
fi

DEPLOYMENT_NAME="$(kubectl get deploy -n "$LOCALSTACK_NAMESPACE" -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}')"
SERVICE_NAME="$(kubectl get svc -n "$LOCALSTACK_NAMESPACE" -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}')"

if [ -z "$DEPLOYMENT_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "[ERROR] No se pudieron localizar deployment/service de LocalStack"
    exit 1
fi

kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$LOCALSTACK_NAMESPACE" --timeout=180s

LOCALSTACK_NODEPORT="$(kubectl -n "$LOCALSTACK_NAMESPACE" get svc "$SERVICE_NAME" -o jsonpath='{.spec.ports[0].nodePort}')"
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"

if [ -z "$LOCALSTACK_NODEPORT" ] || [ -z "$NODE_IP" ]; then
    echo "[ERROR] No se pudo resolver endpoint de LocalStack (nodeIP/nodePort)"
    exit 1
fi

LOCALSTACK_ENDPOINT_URL="${LOCALSTACK_ENDPOINT_URL:-http://${NODE_IP}:${LOCALSTACK_NODEPORT}}"

echo "[INFO] Endpoint LocalStack detectado: $LOCALSTACK_ENDPOINT_URL"

# Endpoint de health de LocalStack
if ! curl -fsS "${LOCALSTACK_ENDPOINT_URL}/_localstack/health" >/dev/null 2>&1; then
    echo "[ERROR] LocalStack no responde en ${LOCALSTACK_ENDPOINT_URL}"
    exit 1
fi

gh_group_end

# -----------------------------
# Crear bucket para tfstate (idempotente)
# -----------------------------
gh_group "Crear bucket tfstate"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PAGER=""

if aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api head-bucket --bucket "$TFSTATE_BUCKET" >/dev/null 2>&1; then
    echo "[INFO] El bucket '$TFSTATE_BUCKET' ya existe. Continuando..."
else
    echo "[INFO] El bucket '$TFSTATE_BUCKET' no existe. Creando..."
    if [ "$AWS_DEFAULT_REGION" = "us-east-1" ]; then
        aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api create-bucket \
            --bucket "$TFSTATE_BUCKET"
    else
        set +e
        CREATE_OUTPUT="$(aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api create-bucket \
            --bucket "$TFSTATE_BUCKET" \
            --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" 2>&1)"
        CREATE_EXIT_CODE=$?
        set -e

        if [ $CREATE_EXIT_CODE -ne 0 ]; then
            if echo "$CREATE_OUTPUT" | grep -q "InvalidLocationConstraint"; then
                echo "[WARN] LocalStack rechazo LocationConstraint '$AWS_DEFAULT_REGION'. Reintentando sin LocationConstraint..."
                aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api create-bucket \
                    --bucket "$TFSTATE_BUCKET"
            else
                echo "$CREATE_OUTPUT"
                exit $CREATE_EXIT_CODE
            fi
        fi
    fi
    echo "[SUCCESS] Bucket '$TFSTATE_BUCKET' creado"
fi

aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api list-buckets --query "Buckets[].Name" --output text

gh_group_end

echo "[SUCCESS] Bucket de Terraform state listo: $TFSTATE_BUCKET"
