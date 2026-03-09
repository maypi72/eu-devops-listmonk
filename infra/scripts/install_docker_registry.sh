#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalacion de Docker Registry local con Helm ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../values/registry-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/infra/values/registry-values.yaml"
fi

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-docker-registry}"
REGISTRY_RELEASE_NAME="${REGISTRY_RELEASE_NAME:-docker-registry}"
REGISTRY_HELM_REPO_NAME="${REGISTRY_HELM_REPO_NAME:-twuni}"
REGISTRY_HELM_REPO_URL="${REGISTRY_HELM_REPO_URL:-https://helm.twun.io}"
REGISTRY_HELM_CHART="${REGISTRY_HELM_CHART:-twuni/docker-registry}"
REGISTRY_S3_BUCKET="${REGISTRY_S3_BUCKET:-docker-registry-data}"

LOCALSTACK_NAMESPACE="${LOCALSTACK_NAMESPACE:-localstack}"
LOCALSTACK_RELEASE_NAME="${LOCALSTACK_RELEASE_NAME:-localstack}"
LOCALSTACK_INTERNAL_ENDPOINT="${LOCALSTACK_INTERNAL_ENDPOINT:-http://localstack.localstack.svc.cluster.local:4566}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY:-test}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${AWS_SECRETE_KEY:-test}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"

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

install_docker_engine() {
    if command -v docker >/dev/null 2>&1; then
        echo "[INFO] Docker ya esta instalado en: $(command -v docker)"
        docker --version || true
        return 0
    fi

    echo "[INFO] Docker no encontrado. Instalando Docker Engine..."

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[ERROR] Solo se soporta instalacion automatica en sistemas basados en apt-get"
        return 1
    fi

    run_privileged apt-get update -y
    run_privileged apt-get install -y ca-certificates curl gnupg lsb-release

    run_privileged install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | run_privileged gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_privileged chmod a+r /etc/apt/keyrings/docker.gpg

    local distro="ubuntu"
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "${ID:-}" = "debian" ]; then
            distro="debian"
        fi
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        | run_privileged tee /etc/apt/sources.list.d/docker.list >/dev/null

    run_privileged apt-get update -y

    if ! run_privileged apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "[WARN] No se pudo instalar desde repo oficial. Probando paquetes de distro..."
        run_privileged apt-get install -y docker.io docker-compose-plugin docker-compose
    fi

    if command -v systemctl >/dev/null 2>&1; then
        run_privileged systemctl enable --now docker || true
    fi

    command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker no pudo instalarse"; return 1; }
    docker --version || true
}

ensure_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "[INFO] Docker Compose plugin disponible"
        docker compose version || true
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        echo "[INFO] Docker Compose standalone disponible"
        docker-compose --version || true
        return 0
    fi

    echo "[INFO] Docker Compose no encontrado. Instalando..."
    if command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update -y
        if ! run_privileged apt-get install -y docker-compose-plugin; then
            run_privileged apt-get install -y docker-compose
        fi
    else
        echo "[ERROR] No se pudo instalar Docker Compose automaticamente"
        return 1
    fi

    if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
        echo "[INFO] Docker Compose instalado correctamente"
        docker compose version >/dev/null 2>&1 && docker compose version || docker-compose --version
    else
        echo "[ERROR] Docker Compose sigue sin estar disponible"
        return 1
    fi
}

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
        echo "[ERROR] No se encontro gestor soportado para instalar AWS CLI"
        return 1
    fi

    command -v aws >/dev/null 2>&1 || { echo "[ERROR] AWS CLI no pudo instalarse"; return 1; }
    aws --version || true
}

resolve_localstack_external_endpoint() {
    if ! kubectl get ns "$LOCALSTACK_NAMESPACE" >/dev/null 2>&1; then
        echo "[ERROR] Namespace '$LOCALSTACK_NAMESPACE' no existe. Debes desplegar LocalStack primero."
        return 1
    fi

    local service_name node_port node_ip
    service_name="$(kubectl -n "$LOCALSTACK_NAMESPACE" get svc -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    node_port="$(kubectl -n "$LOCALSTACK_NAMESPACE" get svc "$service_name" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

    if [ -z "$service_name" ] || [ -z "$node_port" ] || [ -z "$node_ip" ]; then
        echo "[ERROR] No se pudo resolver endpoint externo de LocalStack"
        return 1
    fi

    LOCALSTACK_ENDPOINT_URL="http://${node_ip}:${node_port}"
    echo "[INFO] Endpoint externo de LocalStack detectado: $LOCALSTACK_ENDPOINT_URL"
}

check_registry_bucket_exists() {
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PAGER=""

    if aws --endpoint-url "$LOCALSTACK_ENDPOINT_URL" s3api head-bucket --bucket "$REGISTRY_S3_BUCKET" >/dev/null 2>&1; then
        echo "[INFO] Bucket dedicado del registry encontrado: $REGISTRY_S3_BUCKET"
        return 0
    fi

    echo "[ERROR] El bucket '$REGISTRY_S3_BUCKET' no existe en LocalStack"
    echo "[ERROR] Crea el bucket con Terraform (resource aws_s3_bucket.docker_registry) y aplica cambios antes de desplegar el registry"
    return 1
}

gh_group "Pre-chequeos"

if [ ! -f "$VALUES_FILE" ]; then
    echo "[ERROR] No se encontro el archivo de values en: $VALUES_FILE"
    exit 1
fi

echo "[INFO] Usando values: $VALUES_FILE"

for cmd in kubectl helm curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

if [ ! -r "$KUBECONFIG" ]; then
    echo "[ERROR] No se puede leer KUBECONFIG: $KUBECONFIG"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] No hay conectividad con Kubernetes"
    exit 1
fi

install_aws_cli
resolve_localstack_external_endpoint
check_registry_bucket_exists

gh_group_end

gh_group "Verificar/instalar Docker y Compose"
install_docker_engine
ensure_docker_compose
gh_group_end

gh_group "Instalacion Docker Registry"

kubectl create namespace "$REGISTRY_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm repo add "$REGISTRY_HELM_REPO_NAME" "$REGISTRY_HELM_REPO_URL" --force-update
helm repo update "$REGISTRY_HELM_REPO_NAME"

helm upgrade --install "$REGISTRY_RELEASE_NAME" "$REGISTRY_HELM_CHART" \
    --namespace "$REGISTRY_NAMESPACE" \
    -f "$VALUES_FILE" \
    --set-string "configData.storage.s3.bucket=$REGISTRY_S3_BUCKET" \
    --set-string "configData.storage.s3.region=$AWS_DEFAULT_REGION" \
    --set-string "configData.storage.s3.regionendpoint=$LOCALSTACK_INTERNAL_ENDPOINT" \
    --set-string "configData.storage.s3.accesskey=$AWS_ACCESS_KEY_ID" \
    --set-string "configData.storage.s3.secretkey=$AWS_SECRET_ACCESS_KEY" \
    --wait \
    --timeout 300s

gh_group_end

gh_group "Validacion"
helm status "$REGISTRY_RELEASE_NAME" -n "$REGISTRY_NAMESPACE"
kubectl get pods -n "$REGISTRY_NAMESPACE" -o wide
kubectl get svc -n "$REGISTRY_NAMESPACE"
gh_group_end

echo "[SUCCESS] Docker Registry desplegado en namespace '$REGISTRY_NAMESPACE'"
