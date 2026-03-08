#!/bin/bash

set -e

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

echo "🔧 Instalación de K3s para MF8"
echo ""

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Verificar si ya está instalado
if command -v k3s &> /dev/null; then
    echo -e "${YELLOW}⚠️  K3s ya está instalado${NC}"
    k3s --version
    echo ""
    # en entornos no interactivos (CI, GitHub Actions) no preguntamos
    if [ -t 0 ]; then
        read -p "¿Deseas reinstalarlo? (s/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            echo "Instalación cancelada"
            exit 0
        fi
    fi
    echo "" 
    echo "🗑️  Desinstalando K3s existente..."
    /usr/local/bin/k3s-uninstall.sh || true
    sleep 2
fi

gh_group "Requisitos básicos"
# Verificar requisitos
echo "📋 Verificando requisitos..."

if ! command -v curl &> /dev/null; then
    echo -e "${RED}❌ curl no está instalado${NC}"
    exit 1
fi

# Verificar sistema operativo
OS=$(uname -s)
if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
    echo -e "${RED}❌ Sistema operativo no soportado: $OS${NC}"
    echo "K3s solo funciona en Linux y macOS"
    exit 1
fi

# variables de Calico (CNI)
CALICO_VERSION="${CALICO_VERSION:-v3.27.2}"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo -e "${GREEN}✅ Sistema compatible${NC}"
echo ""
gh_group_end

gh_group "Instalar k3s y componentes"
# Instalar K3s
echo "📥 Descargando e instalando K3s..."
echo ""

if [[ "$OS" == "Darwin" ]]; then
    echo -e "${YELLOW}⚠️  En macOS, K3s requiere Docker Desktop o Rancher Desktop${NC}"
    echo "Alternativas recomendadas para macOS:"
    echo "  - Minikube: brew install minikube && minikube start"
    echo "  - OrbStack: https://orbstack.dev/"
    echo "  - Docker Desktop: Activar Kubernetes en preferencias"
    echo ""
    if [ -t 0 ]; then
        read -p "¿Continuar con K3s de todos modos? (s/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 0
        fi
    fi
fi

# opciones fijas de instalación para deshabilitar componentes y usar Calico
K3S_EXEC_OPTS="--disable traefik --disable servicelb --flannel-backend=none --disable-network-policy --write-kubeconfig-mode 644"

# Instalar K3s con las opciones arriba
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$K3S_EXEC_OPTS" sh -s -

# permisos del kubeconfig global
chmod 644 /etc/rancher/k3s/k3s.yaml || true

# esperar API server
echo ""
echo "⏳ Esperando a que K3s esté listo..."
# k3s instala rápidamente, pero nos damos unos segundos
sleep 10

# Configurar kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# instalar kubectl standalone si no existe (para que cualquier usuario pueda usarlo)
if ! command -v kubectl &> /dev/null; then
    echo "📦 instalando kubectl independiente..."
    KVER=$(k3s kubectl version -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^\"]+' || true)
    if [ -z "$KVER" ]; then
        KVER=$(curl -sL https://dl.k8s.io/release/stable.txt)
    fi
    curl -fsSL https://dl.k8s.io/release/${KVER}/bin/linux/$(uname -m)/kubectl -o /tmp/kubectl
    chmod +x /tmp/kubectl
    mv /tmp/kubectl /usr/local/bin/kubectl
fi

# Asegurar permisos para que todos los usuarios puedan leer el kubeconfig
chmod a+r /etc/rancher/k3s/k3s.yaml || true



# Verificar instalación
if kubectl get nodes &> /dev/null; then
    echo -e "${GREEN}✅ K3s instalado correctamente${NC}"
    echo ""
    kubectl get nodes
    echo ""
    # instalar Calico si no está presente
    if ! kubectl -n kube-system get daemonset calico-node >/dev/null 2>&1; then
        echo "🔗 instalando Calico CNI..."
        curl -fsSL "$CALICO_URL" -o /tmp/calico.yaml
        # ajustar IPPool si viene con 192.168.0.0/16
        if grep -q "192.168.0.0/16" /tmp/calico.yaml; then
            echo "🔧 ajustando IPPool por defecto a 10.42.0.0/16"
            sed -i "s#192.168.0.0/16#10.42.0.0/16#g" /tmp/calico.yaml
        fi
        kubectl apply -f /tmp/calico.yaml
        echo "⏳ esperando a que calico-node se despliegue..."
        kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s || true
    else
        echo "✅ Calico ya estaba instalado"
    fi

    echo "📝 Ajustes útiles:"
    echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"  
    echo "  # el fichero ya es legible por cualquier usuario, así que pueden usar kubectl sin sudo"
    echo "  # si prefieres una copia personal:"
    echo "    mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && chown \$USER ~/.kube/config"
    echo ""
else
    echo -e "${RED}❌ Error al instalar K3s${NC}"
    echo "Revisa los logs: sudo journalctl -u k3s"
    exit 1
fi

echo "✅ Instalación completada"
gh_group_end
gh_group "Instalar Helm"
if ! command -v helm >/dev/null 2>&1; then
    echo "[INFO] Instalando Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
else
    echo "[INFO] Helm ya instalado"
fi
gh_group_end