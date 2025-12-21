helm repo add minio https://charts.min.io/
helm repo update

helm upgrade --install minio minio/minio \
  -n logging \
  -f minio-prod-values.yaml


kubectl get pods -n logging
kubectl get svc -n logging
