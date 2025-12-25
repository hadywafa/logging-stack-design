# Steps

## Install dependencies

```bash
helm dependency update
```

---

## Deploy Dev Chart

### Step 1 — MinIO

```bash
helm repo add minio https://charts.min.io/
helm repo update

helm upgrade --install minio minio/minio \
  -n logging \
  --create-namespace \
  -f minio-dev-values.yaml
```

Verify MinIO → create bucket.

```bash
kubectl port-forward svc/minio-console 9001 -n logging
```

create logs-dev using cli

```bash
mc alias set minio http://minio.logging.svc.cluster.local:9000 minioadmin minioadmin123
mc mb minio/logs-preprod
```

---

### Step 2 — Loki

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  -n logging \
  -f loki-dev-values.yaml
```

Verify Loki writes to MinIO.

```bash
kubectl get pods -n logging
kubectl logs deploy/loki-write -n logging
```

---

### Step 3 — Alloy

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install k8s-monitoring grafana/k8s-monitoring \
  -n logging \
  --create-namespace \
  -f alloy-k8s-monitoring-dev-values.yaml
```

Verify Alloy writes to Loki.

```bash
kubectl get pods -n logging
kubectl logs daemonset/alloy -n logging

```

---

## Deploy Prod Charts

### Step 1 — MinIO

```bash
helm upgrade --install logging ./logging-stack \
  -n logging \
  --create-namespace \
  -f prod.yaml \
  --set alloy.enabled=false \
  --set loki.enabled=false
```

Verify MinIO → create bucket.

---

#### Step 2 — Loki

```bash
helm upgrade --install logging ./logging-stack \
  -n logging \
  -f prod.yaml \
  --set alloy.enabled=false
```

Verify Loki writes to MinIO.

---

#### Step 3 — Alloy

```bash
helm upgrade --install logging ./logging-stack \
  -n logging \
  -f prod.yaml
```

## Testing

### Test Alloy

### Test Loki

### Test MinIO
