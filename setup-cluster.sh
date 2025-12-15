#!/bin/bash

set -e

CLUSTER_NAME="greencap-cluster"
KIND_CONFIG="kind-config.yaml"

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

check_tool() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 could not be found. Please install it."
        exit 1
    fi
}

wait_for_pods() {
    local namespace=$1
    local timeout=${2:-180}
    log "Waiting for pods in namespace ${namespace} to be ready..."
    kubectl wait --for=condition=ready pod --all -n "${namespace}" --timeout="${timeout}s" 2>/dev/null || true
}

configure_hosts() {
    local hostsEntry="127.0.0.1 web-app.greencap harbor.greencap kube-dash.greencap"
    if grep -q "greencap" /etc/hosts 2>/dev/null; then
        log "Hosts entries already configured."
    else
        log "Configuring /etc/hosts..."
        echo "${hostsEntry}" | sudo tee -a /etc/hosts > /dev/null
        log "Added: ${hostsEntry}"
    fi
}

# Check dependencies
check_tool kind
check_tool kubectl
check_tool helm
check_tool openssl

# Create Cluster
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    log "Cluster ${CLUSTER_NAME} already exists."
else
    log "Creating cluster ${CLUSTER_NAME}..."
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
fi

# Context setup
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

log "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

log "Installing Traefik via Helm..."
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Configure Traefik:
# - Enable Gateway API
# - Set NodePorts for external access
# - Allow insecure backend (for Dashboard self-signed certs)
helm upgrade --install traefik traefik/traefik \
    --namespace traefik --create-namespace \
    --set providers.kubernetesGateway.enabled=true \
    --set ports.web.nodePort=30001 \
    --set ports.websecure.nodePort=30002 \
    --set service.type=NodePort \
    --set "additionalArguments={--serversTransport.insecureSkipVerify=true}"

wait_for_pods traefik 120

log "Generatng Self-Signed Certificate for *.greencap..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout greencap.key -out greencap.crt \
    -subj "/CN=*.greencap/O=GreenCap/C=US" \
    -addext "subjectAltName = DNS:*.greencap" 2>/dev/null

log "Creating TLS Secret..."
kubectl create secret tls greencap-tls --cert=greencap.crt --key=greencap.key --dry-run=client -o yaml | kubectl apply -f -
rm greencap.key greencap.crt

log "Installing Kubernetes Dashboard via Helm..."
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo update

# Dashboard setup
# Enable Kong as it is required for internal routing between microservices (web, api, auth).
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --namespace kubernetes-dashboard --create-namespace \
    --set cert-manager.enabled=false \
    --set nginx.enabled=false

wait_for_pods kubernetes-dashboard 120

# Create ServiceAccount and Token for Dashboard (Helper)
log "Creating Dashboard Service Account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Get Token
log "Dashboard Token:"
kubectl -n kubernetes-dashboard create token admin-user

log "Deploying Test Application (Namespace: web-app)..."
kubectl create namespace web-app --dry-run=client -o yaml | kubectl apply -f -
kubectl create deployment web-app --image=nginx --port=80 -n web-app --dry-run=client -o yaml | kubectl apply -f -
kubectl expose deployment web-app --port=80 --target-port=80 --type=ClusterIP -n web-app --dry-run=client -o yaml | kubectl apply -f -

log "Configuring Gateway and Routes..."
kubectl apply -f manifests/gateway.yaml
kubectl apply -f manifests/routes.yaml

log "Configuring /etc/hosts..."
configure_hosts

# Annotate Dashboard Service for HTTPS backend protocol
log "Annotating Dashboard Proxy Service for HTTPS..."
kubectl annotate service -n kubernetes-dashboard kubernetes-dashboard-kong-proxy traefik.ingress.kubernetes.io/service.serversscheme=https --overwrite

log "Setup Complete!"
log ""
log "=== Access URLs ==="
log "Web App:        http://web-app.greencap:30001"
log "Dashboard:      https://kube-dash.greencap:30002"
log ""
