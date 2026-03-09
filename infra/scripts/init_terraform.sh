#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Terraform init (backend remoto en LocalStack) ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/infra/terraform}"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.8.5}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-terraform-tfstate}"
TFSTATE_KEY="${TFSTATE_KEY:-bootstrap/terraform.tfstate}"
TF_BACKEND_ENDPOINT="${TF_BACKEND_ENDPOINT:-${LOCALSTACK_ENDPOINT_URL:-}}"
LOCALSTACK_NAMESPACE="${LOCALSTACK_NAMESPACE:-localstack}"
LOCALSTACK_RELEASE_NAME="${LOCALSTACK_RELEASE_NAME:-localstack}"

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

resolve_localstack_endpoint() {
    if [ -n "$TF_BACKEND_ENDPOINT" ]; then
        echo "[INFO] Usando endpoint de backend definido por variable: $TF_BACKEND_ENDPOINT"
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        TF_BACKEND_ENDPOINT="http://localhost:31566"
        echo "[WARN] kubectl no disponible, usando endpoint por defecto: $TF_BACKEND_ENDPOINT"
        return 0
    fi

    local service_name node_ip node_port
    service_name="$(kubectl -n "$LOCALSTACK_NAMESPACE" get svc -l app.kubernetes.io/instance="$LOCALSTACK_RELEASE_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

    if [ -n "$service_name" ] && [ -n "$node_ip" ]; then
        node_port="$(kubectl -n "$LOCALSTACK_NAMESPACE" get svc "$service_name" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
        if [ -n "$node_port" ]; then
            TF_BACKEND_ENDPOINT="http://${node_ip}:${node_port}"
            echo "[INFO] Endpoint de LocalStack detectado automaticamente: $TF_BACKEND_ENDPOINT"
            return 0
        fi
    fi

    TF_BACKEND_ENDPOINT="http://localhost:31566"
    echo "[WARN] No se pudo detectar endpoint de LocalStack por kubectl. Usando fallback: $TF_BACKEND_ENDPOINT"
}

install_terraform() {
    if command -v terraform >/dev/null 2>&1; then
        echo "[INFO] Terraform ya esta instalado"
        terraform version
        return 0
    fi

    echo "[INFO] Terraform no encontrado. Instalando v${TERRAFORM_VERSION}..."

    if ! command -v unzip >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update -y
            run_privileged apt-get install -y unzip
        else
            echo "[ERROR] No se encontro unzip y no hay apt-get para instalarlo"
            return 1
        fi
    fi

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64) TF_ARCH="amd64" ;;
        aarch64|arm64) TF_ARCH="arm64" ;;
        *) echo "[ERROR] Arquitectura no soportada: $ARCH"; return 1 ;;
    esac

    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    TF_ZIP="terraform_${TERRAFORM_VERSION}_${OS}_${TF_ARCH}.zip"
    TF_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TF_ZIP}"

    TMP_DIR="$(mktemp -d)"
    curl -fsSL "$TF_URL" -o "$TMP_DIR/$TF_ZIP"
    unzip -q "$TMP_DIR/$TF_ZIP" -d "$TMP_DIR"
    run_privileged install -m 0755 "$TMP_DIR/terraform" /usr/local/bin/terraform
    rm -rf "$TMP_DIR"

    terraform version
}

gh_group "Pre-chequeos"

if [ ! -d "$TF_DIR" ]; then
    echo "[ERROR] Directorio de Terraform no encontrado: $TF_DIR"
    exit 1
fi

if ! compgen -G "$TF_DIR/*.tf" >/dev/null; then
    echo "[ERROR] No se encontraron archivos .tf en: $TF_DIR"
    exit 1
fi

for cmd in curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

gh_group_end

gh_group "Verificar/instalar Terraform"
install_terraform
gh_group_end

gh_group "Resolver endpoint backend"
resolve_localstack_endpoint
gh_group_end

gh_group "Terraform init"
terraform -chdir="$TF_DIR" init -reconfigure \
  -backend-config="bucket=$TFSTATE_BUCKET" \
  -backend-config="key=$TFSTATE_KEY" \
  -backend-config="region=$AWS_DEFAULT_REGION" \
  -backend-config="access_key=$AWS_ACCESS_KEY_ID" \
  -backend-config="secret_key=$AWS_SECRET_ACCESS_KEY" \
  -backend-config="endpoint=$TF_BACKEND_ENDPOINT" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_metadata_api_check=true" \
  -backend-config="skip_region_validation=true" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config="force_path_style=true"
gh_group_end

echo "[SUCCESS] Terraform init completado en $TF_DIR"
