helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  -n logging \
  -f loki-prod-values.yaml


kubectl get pods -n logging
kubectl logs deploy/loki-write -n logging
