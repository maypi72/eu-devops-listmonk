#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === K3s Lab: Instalación NGINX Ingress (Calico Compatible) ==="

# -----------------------------
# Configuración Dinámica de Rutas
# -----------------------------
# Calculamos la ruta base del script para localizar el archivo de values.
# Prioridad: ruta relativa al repo (../values) y fallback a GITHUB_WORKSPACE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../values/ingress-values.yaml"
if [ ! -f "$VALUES_FILE" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    VALUES_FILE="$GITHUB_WORKSPACE/infra/values/ingress-values.yaml"
fi

# Forzamos KUBECONFIG para evitar errores de permisos/autoridad
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Parámetros del Chart
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_CHART_VERSION="4.10.1"
HELM_REPO_NAME="ingress-nginx"
HELM_REPO_URL="https://kubernetes.github.io/ingress-nginx"
RELEASE_NAME="ingress-nginx"

# Helpers para GitHub Actions
gh_group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "[INFO] $*"; }
gh_group_end() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || echo ""; }

# -----------------------------
# Pre-chequeos
# -----------------------------
gh_group "Pre-chequeos"

# 1. Validar existencia del archivo de valores
if [ ! -f "$VALUES_FILE" ]; then
    echo "[ERROR] No se encontró el archivo de valores en: $VALUES_FILE"
    exit 1
fi

# 2. Permisos de KUBECONFIG
if [ ! -r "$KUBECONFIG" ]; then
    echo "[INFO] Ajustando permisos de Kubeconfig para el runner..."
    sudo chmod 644 "$KUBECONFIG"
fi

# 3. Herramientas necesarias
for cmd in kubectl helm curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd no encontrado"; exit 1; }
done

# 4. Conexión al Cluster
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] El runner no puede conectar con K3s. Revisa el servicio k3s."
    exit 1
fi
gh_group_end

# -----------------------------
# Instalación con Helm
# -----------------------------
gh_group "Instalación de Ingress Controller"

echo "[INFO] Actualizando repositorio $HELM_REPO_NAME..."
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update
helm repo update "$HELM_REPO_NAME"

# Crear namespace si no existe
kubectl create namespace "$INGRESS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Ejecutando Helm Upgrade/Install desde $VALUES_FILE..."
helm upgrade --install "$RELEASE_NAME" "$HELM_REPO_NAME/ingress-nginx" \
    --namespace "$INGRESS_NAMESPACE" \
    --version "$INGRESS_CHART_VERSION" \
    -f "$VALUES_FILE" \
    --wait \
    --timeout 300s

gh_group_end

# -----------------------------
# Validación Final
# -----------------------------
gh_group "Validación de Estado"
echo "[INFO] Verificando pods en $INGRESS_NAMESPACE..."
kubectl get pods -n "$INGRESS_NAMESPACE" -o wide

if kubectl rollout status daemonset/"$RELEASE_NAME"-controller -n "$INGRESS_NAMESPACE" --timeout=60s; then
    echo "[SUCCESS] NGINX Ingress Controller está desplegado y listo."
else
    echo "[ERROR] El despliegue falló o tardó demasiado."
    exit 1
fi
gh_group_end
