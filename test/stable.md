You are **very close**. Your Loki is failing for one specific reason, and it explains everything you see:

* **Grafana shows no logs**
* **MinIO bucket stays empty**
* Loki logs show: `no EC2 IMDS role found` / `failed to refresh cached credentials`
* Ring becomes unhealthy: `too many unhealthy instances in the ring`

## Root cause (100%)

Loki is **not actually using your MinIO credentials**, so the AWS SDK falls back to the default provider chain and tries **EC2 IMDS** (Instance Metadata Service). In AKS, that fails (404/403), so Loki cannot `PutObject` to MinIO → **no chunks written** → no data → ring unhealthy.

This is exactly what your Loki log is saying. The fix is to provide credentials in the **exact Helm keys the chart renders into Loki config**, not in mixed/incorrect blocks.

---

# 1) Confirm the “latest” versions you asked for

* **Latest Grafana Loki Helm chart** in Grafana repo is **`grafana/loki` chart `6.49.0`** (Dec 12, 2025). ([Artifact Hub][1])
* Loki server releases are currently in the **3.6 line**, with **3.6.3 (Dec 11, 2025)** shown as latest by a reputable tracker. ([endoflife.date][2])

So using **chart 6.49.0 is fine**.

---

# 2) The “final correct” Loki values for MinIO (chart 6.49.0)

This version is aligned to the **official Helm install docs** (scalable mode) and uses the keys that chart expects. ([Grafana Labs][3])

## ✅ `loki-dev-values.yaml` (SimpleScalable + MinIO over HTTP)

> This is intentionally minimal and avoids the `storage_config.aws` confusion.
> It forces Loki to use MinIO credentials explicitly.

```yaml
deploymentMode: SimpleScalable

loki:
  auth_enabled: false

  # Required by v6+ chart validation: schemaConfig must exist
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  # Recommended knobs from official install docs (safe for dev)
  pattern_ingester:
    enabled: true

  limits_config:
    allow_structured_metadata: true
    volume_enabled: true

  querier:
    max_concurrent: 2

  # IMPORTANT: This section is what the Helm chart renders into Loki config
  storage:
    type: s3

    bucketNames:
      chunks: logs-dev
      ruler: logs-dev
      admin: logs-dev

    s3:
      endpoint: http://minio.logging.svc.cluster.local:9000
      region: us-east-1

      # MinIO-specific
      s3ForcePathStyle: true
      insecure: true

      # CRITICAL: provide credentials HERE so Loki never tries IMDS
      accessKeyId: minioadmin
      secretAccessKey: minioadmin123

# Dev sizing
write:
  replicas: 1
read:
  replicas: 1
backend:
  replicas: 1

# Avoid extra components that can fail on small clusters
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Optional: if you want public access for testing via Azure LB
gateway:
  service:
    type: ClusterIP
```

Why this works:

* It follows the official Helm scalable template structure. ([Grafana Labs][3])
* It sets **MinIO credentials at `loki.storage.s3.accessKeyId/secretAccessKey`**, so the AWS SDK does not attempt IMDS.

---

# 3) Clean reinstall (you must do this to remove the broken config)

Because you have CrashLooping and old generated config, do a clean reinstall.

```bash
helm uninstall loki -n logging

# If Helm created PVCs/WAL that keep bad state, remove them too (safe in dev)
kubectl delete pvc -n logging -l app.kubernetes.io/instance=loki --ignore-not-found

helm upgrade --install loki grafana/loki \
  -n logging \
  -f loki-dev-values.yaml
```

Now validate:

```bash
kubectl get pods -n logging
kubectl logs -n logging sts/loki-write --since=5m | egrep -i "s3|putobject|flush|error" | tail -n 50
```

Expected:

* You should **NOT** see any more `EC2 IMDS` messages.
* You should start seeing successful flush activity without S3 credential errors.

---

# 4) Fix your Alloy output URL (most common mistake)

Your Alloy values included **two different URLs** (one correct push endpoint, one not). You must push to:

✅ `http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push`

If you use only `http://loki-gateway.logging.svc.cluster.local` without the push path (depending on chart/component), it may not push correctly.

## Quick sanity test from inside the cluster

Run a temporary curl pod:

```bash
kubectl run -n logging curl --rm -it --image=curlimages/curl -- sh
```

Inside it:

```sh
curl -s -o /dev/null -w "%{http_code}\n" \
  http://loki-gateway.logging.svc.cluster.local/ready

curl -s -o /dev/null -w "%{http_code}\n" \
  http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push
```

Expected:

* `/ready` should be **200**
* `/loki/api/v1/push` will typically be **405** (method not allowed) when called with GET — that’s fine, it proves the route exists.

---

# 5) The LogQL query to find your `log-test` pod

Your pod has:

* namespace: `default`
* label: `app=log-test`
* pod name: `log-test`

In Grafana Explore (Loki datasource), use one of these:

### Option A (most reliable)

```logql
{namespace="default", pod="log-test"}
```

### Option B (label-based)

```logql
{namespace="default", app="log-test"}
```

### If your labels are different (common with Alloy relabeling)

Try:

```logql
{pod="log-test"}
```

Then expand labels in Grafana to see what Alloy actually attached.

---

# 6) Prove logs are stored in MinIO (do not rely on UI)

Even if Grafana shows logs, you still want proof that objects exist in the bucket.

## Check objects from inside cluster using MinIO client (`mc`)

Run a temp pod:

```bash
kubectl run -n logging mc --rm -it --image=minio/mc -- sh
```

Inside it:

```sh
mc alias set minio http://minio.logging.svc.cluster.local:9000 minioadmin minioadmin123
mc ls minio
mc ls minio/logs-dev --recursive | head
```

Expected:

* You will start seeing objects under prefixes like `chunks/` / `index/` etc (depending on TSDB layout).

If `mc ls minio/logs-dev` is empty after a few minutes **and** Loki has no S3 errors, then the remaining issue is **ingestion path** (Alloy not pushing).

---

# 7) Why you saw “ring unhealthy”

This is a downstream symptom:

* Write pod can’t flush to object store → ingester fails → ring health degrades → read/query path complains.

Once S3/MinIO write succeeds, the ring stabilizes.

---

## What I need you to do now (short checklist)

1. Apply the **exact** `loki-dev-values.yaml` above (don’t mix `storage_config.aws` with `loki.storage.s3` in dev).
2. Clean reinstall Loki (uninstall + delete PVCs).
3. Confirm Loki logs show **no IMDS errors**.
4. Query logs using `{namespace="default", pod="log-test"}` in Grafana.
5. Verify MinIO objects with `mc ls minio/logs-dev --recursive`.

If you paste **only these two outputs**, I can pinpoint the remaining gap immediately:

* `kubectl logs -n logging sts/loki-write --since=3m | tail -n 80`
* your Alloy client config snippet (the exact `clients:` URL you’re using)

[1]: https://artifacthub.io/packages/helm/grafana/loki?utm_source=chatgpt.com "loki 6.49.0 · grafana/grafana"
[2]: https://endoflife.date/grafana-loki?utm_source=chatgpt.com "Grafana Loki"
[3]: https://grafana.com/docs/loki/latest/setup/install/helm/install-scalable/ "Install the simple scalable Helm chart | Grafana Loki documentation
"
