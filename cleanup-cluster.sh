#!/bin/bash

set -e

CLUSTER_NAME="greencap-cluster"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Check if cluster exists
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    error "Cluster ${CLUSTER_NAME} does not exist."
    exit 1
fi

log "Deleting cluster ${CLUSTER_NAME}..."
kind delete cluster --name "${CLUSTER_NAME}"

log "Cleaning up temporary files..."
rm -f greencap.key greencap.crt 2>/dev/null || true

log "Cleanup Complete!"
log ""
log "Note: /etc/hosts entries were NOT removed. Remove manually if needed:"
log "sudo sed -i '/greencap/d' /etc/hosts"
