Understood. I will reset this and give you a **single, deterministic runbook** you can follow end-to-end with **zero guessing**, based on what you actually built:

* AKS cluster
* Namespace: `logging`
* MinIO installed (Deployment)
* Loki installed (SimpleScalable; you already see `loki-gateway`, `loki-read`)
* You likely have `loki-write` and `loki-backend` as **StatefulSets**
* Grafana is **Azure Managed Grafana** (you enabled it in AKS)
* You want to verify:

  1. Alloy collected logs
  2. Loki received them
  3. MinIO stored them
  4. Grafana can query them

I will give you **exact commands**, **expected outputs**, and what to do if you don’t see them.

---

# 0) One rule to stop the confusion

## Azure Managed Grafana is NOT inside your cluster

So:

* You do **not** `kubectl port-forward grafana`
* You do **not** open `localhost:3000`

You access it from **Azure Portal** → **Azure Managed Grafana** → **Endpoint**.

---

# 1) Verify what is installed (Kubernetes side)

Run these 3 commands:

```bash
kubectl get pods -n logging
kubectl get deploy -n logging
kubectl get sts -n logging
```

### Expected

* `minio` pod running
* `loki-gateway` and `loki-read` deployments running
* `loki-write` and `loki-backend` statefulsets exist and are running (`-0` pods)

If `kubectl get sts -n logging` shows nothing, Loki install is incomplete.

---

# 2) Verify MinIO bucket exists (CLI only, no UI)

## 2.1 Exec into MinIO pod

First get the pod name:

```bash
kubectl get pods -n logging | grep minio
```

Then exec (replace POD name):

```bash
kubectl exec -it <MINIO_POD_NAME> -n logging -- sh
```

## 2.2 Configure `mc` locally inside the pod

```sh
mc alias set local http://127.0.0.1:9000 minioadmin minioadmin123
```

## 2.3 List buckets

```sh
mc ls local
```

### Expected

You should see `logs-dev`.

If you **don’t**, create it:

```sh
mc mb local/logs-dev
```

Leave the pod shell open for later (or exit; up to you).

---

# 3) Verify Loki is writing to MinIO (this proves storage path)

## 3.1 Check Loki write logs

```bash
kubectl logs sts/loki-write -n logging --tail=100
```

### Expected

* No repeated errors about S3 / bucket / auth
* Specifically you should NOT see:

  * `NoSuchBucket`
  * `AccessDenied`
  * `SignatureDoesNotMatch`

If you see `NoSuchBucket`, go back to step 2 and create the bucket, then restart Loki:

```bash
kubectl rollout restart sts/loki-write -n logging
kubectl rollout restart sts/loki-backend -n logging
kubectl rollout restart deploy/loki-read -n logging
kubectl rollout restart deploy/loki-gateway -n logging
```

## 3.2 Confirm MinIO has objects (hard proof)

Back inside MinIO pod shell:

```sh
mc ls local/logs-dev
```

### Expected (after Loki runs a bit)

You will see folders such as:

* `chunks/`
* `index/`
* `ruler/` (may appear later)

To prove files exist:

```sh
mc ls local/logs-dev/chunks | head
mc ls local/logs-dev/index  | head
```

If you see objects here → ✅ **Loki is saving to MinIO**.

At this stage, even if Grafana is not connected, your backend is correct.

---

# 4) Verify Alloy exists and is shipping logs (collection proof)

Run:

```bash
kubectl get pods -n logging | grep alloy
```

### Expected

At least one Alloy pod per node (DaemonSet), names like `alloy-xxxxx`.

If you see nothing, Alloy is not installed yet.

## 4.1 Check Alloy logs

```bash
kubectl logs ds/alloy -n logging --tail=100
```

### Expected

You should see signs it is:

* discovering pods
* scraping logs
* pushing to Loki (look for push/HTTP 2xx style messages)

If you see connection errors to Loki gateway, your Alloy config URL is wrong.

---

# 5) Create a test app that generates logs (so you have data)

Apply this (copy to `log-test.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: log-test
  namespace: default
  labels:
    app: log-test
spec:
  containers:
    - name: app
      image: busybox
      command: ["sh","-c"]
      args:
        - |
          i=0;
          while true; do
            i=$((i+1));
            echo "ts=$(date -Iseconds) level=INFO app=log-test msg=\"hello $i\"";
            if [ $((i % 10)) -eq 0 ]; then
              echo "ts=$(date -Iseconds) level=ERROR app=log-test msg=\"boom $i\"";
            fi
            sleep 2;
          done
```

Apply:

```bash
kubectl apply -f log-test.yaml
```

Confirm it’s running:

```bash
kubectl logs pod/log-test -n default --tail=20
```

---

# 6) Verify the log-test pod reached Loki (API check, no Grafana yet)

This is the simplest “did Loki ingest?” check.

Port-forward Loki gateway locally (this is short-lived and usually stable because it’s HTTP, not the MinIO websocket UI):

```bash
kubectl port-forward svc/loki-gateway -n logging 3100:80
```

In a second terminal, query labels:

```bash
curl -s "http://127.0.0.1:3100/loki/api/v1/labels" | head
```

Now query for your pod logs (LogQL API):

```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query" \
  --data-urlencode 'query={pod="log-test"}' | head
```

### Expected

You should see JSON response with log lines.

If this works → ✅ Alloy → Loki ingestion is working.

---

# 7) Now Grafana (Azure Managed Grafana) — how to query logs

## 7.1 Access Azure Managed Grafana

Azure Portal → **Azure Managed Grafana** → click **Endpoint**

## 7.2 Add Loki datasource (one time)

Grafana UI:

* **Connections → Data sources → Add data source → Loki**

Now the key question: **what URL do you put?**

### The correct answer

Azure Managed Grafana must reach Loki over the network.
The cleanest approach for your stage is:

✅ **Expose Loki Gateway as an Internal LoadBalancer** (creates a VNet IP)

Create `loki-gateway-ilb.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: loki-gateway-ilb
  namespace: logging
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
  selector:
    app.kubernetes.io/component: gateway
```

Apply:

```bash
kubectl apply -f loki-gateway-ilb.yaml
```

Get the IP:

```bash
kubectl get svc -n logging
```

You will see:

* `loki-gateway` (ClusterIP)
* `loki-gateway-ilb` (LoadBalancer) with an **EXTERNAL-IP** that looks like `10.x.x.x`

That `10.x.x.x` is **private** and is what Azure Managed Grafana can use.

### Loki datasource URL

Use:

```
http://<that-10.x.x.x>
```

Click **Save & Test** → must succeed.

> If Save & Test fails, it is a networking/identity issue in Azure (not Loki). Tell me the exact error text.

---

## 7.3 Query logs in Grafana Explore (exact clicks)

1. Left menu → **Explore**
2. At the top, change datasource from **Azure Monitor** → **Loki**
3. Paste and run:

### Query A: show your test pod logs

```logql
{pod="log-test"}
```

### Query B: parse logfmt fields

```logql
{pod="log-test"} | logfmt
```

### Query C: only errors

```logql
{pod="log-test"} | logfmt | level="ERROR"
```

If these return logs → ✅ Grafana is connected and querying.

---

# 8) Final proof that everything is working

You have end-to-end success if all are true:

1. **Alloy is running**

```bash
kubectl get pods -n logging | grep alloy
```

2. **Loki has ingested logs** (API query works)

```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query" --data-urlencode 'query={pod="log-test"}'
```

3. **MinIO contains chunk/index objects**
   Inside MinIO pod:

```sh
mc ls local/logs-dev/chunks | head
mc ls local/logs-dev/index  | head
```

4. **Grafana Explore returns logs**

```logql
{pod="log-test"}
```

---

# If you tell me ONE thing, I can pinpoint where you are stuck

Run this and paste the output:

```bash
kubectl get svc -n logging
```

That will tell me immediately whether:

* Alloy and Loki are internal-only
* You created an ILB
* Which endpoint Azure Managed Grafana should use

But even without that, the runbook above is the correct sequence and verification method.
