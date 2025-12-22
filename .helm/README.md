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

create logs-dev

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
helm upgrade --install alloy grafana/alloy \
  -n logging \
  -f alloy-dev-values.yaml
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
