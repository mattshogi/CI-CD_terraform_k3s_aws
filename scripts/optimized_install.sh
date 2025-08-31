#!/usr/bin/env bash
# Optimized k3s installation for t3.small with minimal components
set -euo pipefail

echo "[INFO] Starting optimized k3s installation at $(date)"

# Stop existing k3s if running
sudo systemctl stop k3s || true
sudo /usr/local/bin/k3s-uninstall.sh || true

# Remove old data
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/rancher/k3s

# Install k3s with optimized settings
echo "[INFO] Installing k3s with optimized configuration..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable metrics-server \
  --disable-cloud-controller \
  --etcd-disable-snapshots \
  --kube-apiserver-arg=max-requests-inflight=400 \
  --kube-apiserver-arg=max-mutating-requests-inflight=200 \
  --kube-apiserver-arg=request-timeout=300s" sh -

# Wait for k3s to be ready
echo "[INFO] Waiting for k3s to be ready..."
timeout 300 bash -c 'while ! kubectl get nodes &>/dev/null; do sleep 5; done'

# Install minimal nginx ingress
echo "[INFO] Installing nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/baremetal/deploy.yaml

# Wait for ingress controller
echo "[INFO] Waiting for ingress controller..."
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=300s

# Create hello-world deployment
echo "[INFO] Deploying hello-world application..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
      - name: hello-world
        image: hashicorp/http-echo
        args: ["-text=Hello, World!"]
        ports:
        - containerPort: 5678
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "64Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 5678
  selector:
    app: hello-world
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-world
            port:
              number: 80
EOF

# Install lightweight monitoring (Prometheus only)
echo "[INFO] Installing lightweight Prometheus..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  --set server.service.type=NodePort \
  --set server.service.nodePort=30090 \
  --set server.resources.requests.memory=100Mi \
  --set server.resources.limits.memory=200Mi \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set nodeExporter.enabled=false \
  --set pushgateway.enabled=false \
  --wait --timeout=10m

echo "[INFO] Installation completed successfully!"
echo "[INFO] Services available:"
echo "  - Hello World: http://$(curl -s ifconfig.me)/"
echo "  - Prometheus: http://$(curl -s ifconfig.me):30090/"
