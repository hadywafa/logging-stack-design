helm upgrade --install alloy grafana/alloy \
  -n logging \
  -f alloy-prod-values.yaml


kubectl logs daemonset/alloy -n logging
