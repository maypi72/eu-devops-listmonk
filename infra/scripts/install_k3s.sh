#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] === Instalación idempotente de k3s + Calico + Helm ==="

# helpers para GitHub Actions (grupos plegables)
gh_group() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::group::$*"
  else
    echo "[INFO] $*"
  fi
}

gh_group_end() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::endgroup::"
  fi
}

# -----------------------------
# Parámetros/flags (ajustables por env)
# -----------------------------
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
# Soporte de token/URL para joins y cluster multi‑nodo
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_URL="${K3S_URL:-}"
# Opciones adicionales de instalación (p.ej. "--node-taint foo=bar:NoSchedule")
K3S_EXEC_EXTRA="${K3S_EXEC_EXTRA:-}"
# Deshabilitar traefik, servicelb, flannel y network-policy de k3s para usar Calico como único CNI
# además escribimos kubeconfig legible por otros usuarios
K3S_EXEC_OPTS="--disable traefik --disable servicelb --flannel-backend=none --disable-network-policy $K3S_EXEC_EXTRA --write-kubeconfig-mode=644"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"        # k3s por defecto
SVC_CIDR="${SVC_CIDR:-10.43.0.0/16}"        # k3s por defecto
CALICO_VERSION="${CALICO_VERSION:-v3.27.2}"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
# Si deseas forzar la actualización de ~/.kube/config aunque exista, exporta:
#   BACKUP_AND_UPDATE_KUBECONFIG=true
BACKUP_AND_UPDATE_KUBECONFIG="${BACKUP_AND_UPDATE_KUBECONFIG:-false}"
# Detectar arquitectura (para kubectl opcional)
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) KARCH="amd64" ;;
  aarch64|arm64) KARCH="arm64" ;;
  *) KARCH="amd64"; echo "[WARN] Arquitectura '$ARCH' no reconocida, usando amd64 por defecto." ;;
esac

# comprobar herramientas básicas y ofrecer instalación automática
install_package() {
    pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y "$pkg"
    else
        echo "[ERROR] No sé cómo instalar paquetes en esta distro, instala '$pkg' manualmente."
        exit 1
    fi
}

for cmd in uname date timeout grep sed mkdir chmod cp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] '$cmd' no encontrado, necesario para el script."
        exit 1
    fi
done

# curl es especial: lo instalamos si falta
if ! command -v curl >/dev/null 2>&1; then
    echo "[INFO] curl no está instalado; intentando instalarlo."
    install_package curl
fi

# sudo condicional (GH runner suele ser root, self-hosted puede no serlo)
# usamos "sudo -n" para evitar prompts interactivos; el job fallará si no hay privilegios.
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo -n"
    else
        echo "[ERROR] No soy root y no hay sudo disponible. Ejecuta el script como root o añade sudo."
        exit 1
    fi
fi

# Determinar el usuario real (cuando se ejecuta con sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
KUBE_DIR="${REAL_HOME}/.kube"
KUBE_FILE="${KUBE_DIR}/config"

# Pre-chequeos básicos
# -----------------------------
gh_group "Pre-chequeos y conectividad"
echo "[INFO] Verificando conectividad para descargas..."
if ! curl -sfL https://get.k3s.io >/dev/null; then
  echo "[ERROR] No hay conectividad para descargar k3s (get.k3s.io)"; exit 1
fi
if ! curl -sfL "$CALICO_URL" >/dev/null; then
  echo "[ERROR] No hay conectividad para descargar el manifiesto de Calico: $CALICO_URL"; exit 1
fi
gh_group_end
# -----------------------------
# sysctl recomendados para Calico
# -----------------------------
gh_group "Configuración de sysctl"
echo "[INFO] Ajustando sysctl para networking (rp_filter/ip_forward)..."
$SUDO sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
$SUDO sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
$SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null
gh_group_end
# -----------------------------
# Instalar k3s
# -----------------------------
gh_group "Instalar k3s"
if command -v k3s >/dev/null 2>&1; then
    echo "[INFO] k3s ya está instalado"
else
    echo "[INFO] Instalando k3s (sin flannel, sin traefik, sin servicelb)..."
    # construir entorno de instalación con token/URL si se proporcionan
    INSTALL_ENV=""
    [ -n "$K3S_TOKEN" ] && INSTALL_ENV="${INSTALL_ENV}K3S_TOKEN=$K3S_TOKEN "
    [ -n "$K3S_URL" ] && INSTALL_ENV="${INSTALL_ENV}K3S_URL=$K3S_URL "
    INSTALL_ENV+="INSTALL_K3S_CHANNEL=\"$K3S_CHANNEL\" INSTALL_K3S_EXEC=\"$K3S_EXEC_OPTS\""

    curl -sfL https://get.k3s.io | eval "$INSTALL_ENV" sh -
    # ensure kubeconfig permissions are open
    $SUDO chmod 644 /etc/rancher/k3s/k3s.yaml || true
fi
gh_group_end
# Esperar API server listo
echo "[INFO] Esperando a que el API server de k3s esté listo..."
timeout 120 bash -c 'until $SUDO k3s kubectl get --raw=/readyz &>/dev/null; do sleep 3; done' || {
  echo "[WARN] API server tardó más de 120s en /readyz; continuando igualmente..."
}
# -----------------------------
# kubectl (opcional, standalone)
# -----------------------------
gh_group "Instalar kubectl"
if ! command -v kubectl >/dev/null 2>&1; then
    echo "[INFO] Instalando kubectl standalone (arquitectura: $KARCH)..."
    KVER="$($SUDO k3s kubectl version -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^\"]+' | head -n1 || true)"
    if [ -z "${KVER:-}" ]; then
      echo "[WARN] No pude detectar la versión del server; usaré 'stable'."
      KVER="$(curl -sL https://dl.k8s.io/release/stable.txt)"
    fi
    curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl" -o kubectl
    chmod +x kubectl
    $SUDO mv kubectl /usr/local/bin/
else
    echo "[INFO] kubectl ya instalado"
fi
gh_group_end
# -----------------------------
# Helm
# -----------------------------
gh_group "Instalar Helm"
if ! command -v helm >/dev/null 2>&1; then
    echo "[INFO] Instalando Helm..."
    # el script de Helm pide sudo internamente; se lo pasamos para evitar prompts
    curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | $SUDO bash
else
    echo "[INFO] Helm ya instalado"
fi
gh_group_end
# -----------------------------
# Calico (CNI con manifiestos oficiales)
# -----------------------------
gh_group "Instalar Calico"
if $SUDO k3s kubectl get daemonset -n kube-system calico-node >/dev/null 2>&1; then
    echo "[INFO] Calico ya instalado"
else
    echo "[INFO] Instalando Calico (CNI) para k3s..."
    curl -fsSL "$CALICO_URL" -o /tmp/calico.yaml
    # Ajustar IPPool si el manifiesto trae 192.168.0.0/16
    if grep -q "192.168.0.0/16" /tmp/calico.yaml; then
      echo "[INFO] Ajustando IPPool por defecto de Calico a ${POD_CIDR}"
      sed -i "s#192.168.0.0/16#${POD_CIDR}#g" /tmp/calico.yaml
    fi
    $SUDO k3s kubectl apply -f /tmp/calico.yaml
fi

echo "[INFO] Esperando a Calico (calico-node DaemonSet) que esté listo..."
if ! $SUDO k3s kubectl rollout status daemonset/calico-node -n kube-system --timeout=600s; then
  echo "[WARN] calico-node no listo tras 600s, mostrando estado:"
  $SUDO k3s kubectl get pods -n kube-system -l k8s-app=calico-node -o wide || true
fi

gh_group_end
# Validación adicional de CoreDNS (red funcional)
echo "[INFO] Validando CoreDNS..."
$SUDO k3s kubectl rollout status deployment/coredns -n kube-system --timeout=180s || true
# -----------------------------
# KUBECONFIG para el usuario (idempotente)
# -----------------------------
gh_group "Configurar kubeconfig de usuario"
if [ -f "$KUBECONFIG_PATH" ]; then
  echo "[INFO] KUBECONFIG de k3s encontrado en $KUBECONFIG_PATH"
  # Export para la sesión actual (útil si el script continúa)
  export KUBECONFIG="$KUBECONFIG_PATH"
  # Asegurar ~/.kube/config del usuario real
  mkdir -p "$KUBE_DIR"
  if [ ! -f "$KUBE_FILE" ]; then
      echo "[INFO] Creando ${KUBE_FILE} a partir de ${KUBECONFIG_PATH}"
      $SUDO cp "$KUBECONFIG_PATH" "$KUBE_FILE"
      $SUDO chown "$REAL_USER":"$REAL_USER" "$KUBE_FILE"
      chmod 600 "$KUBE_FILE"
  else
      # Si existe, no sobrescribir por defecto
      if [ "${BACKUP_AND_UPDATE_KUBECONFIG}" = "true" ]; then
          TS="$(date +%Y%m%d-%H%M%S)"
          BACKUP_FILE="${KUBE_FILE}.bak.${TS}"
          echo "[INFO] Realizando backup de ${KUBE_FILE} en ${BACKUP_FILE} y actualizando"
          $SUDO cp "$KUBE_FILE" "$BACKUP_FILE"
          $SUDO cp "$KUBECONFIG_PATH" "$KUBE_FILE"
          $SUDO chown "$REAL_USER":"$REAL_USER" "$KUBE_FILE"
          chmod 600 "$KUBE_FILE"
      else
          echo "[INFO] ${KUBE_FILE} ya existe; no se sobrescribe (BACKUP_AND_UPDATE_KUBECONFIG=false)"
      fi
  fi
else
  echo "[WARN] No se encontró $KUBECONFIG_PATH; usar '
  $SUDO k3s kubectl ...' hasta que esté disponible."
fi
echo "[INFO] k3s + Calico + Helm listos. Kubeconfig del usuario preparado."
gh_group_end