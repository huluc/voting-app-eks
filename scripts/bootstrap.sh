#!/usr/bin/env bash
# Prepares a fresh EKS cluster for the voting app (run once after ./up.sh).
set -euo pipefail

CLUSTER="eks-hilal"
REGION="us-east-1"
NAMESPACE="voting-app"
NGF_VERSION="2.8.0"
ROLE_ARN="arn:aws:iam::686699774218:role/github-actions-voting-app-hilal"
SSM_DB_PASSWORD="/voting-app/hilal/db-password"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 1/4 Connect kubectl to the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "==> 2/4 Gateway API CRDs and NGINX Gateway Fabric"
# CRDs are vendored in the repo so the script doesn't depend on GitHub at run time.
# They must match NGF_VERSION. After changing NGF_VERSION, regenerate them:
#   git clone --depth 1 --branch v<NGF_VERSION> https://github.com/nginx/nginx-gateway-fabric /tmp/ngf
#   kubectl kustomize /tmp/ngf/config/crd/gateway-api/standard > k8s/platform/crds/gateway-api.yaml
kubectl apply -f "$REPO_ROOT/k8s/platform/crds/gateway-api.yaml"
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "$NGF_VERSION" --create-namespace -n nginx-gateway --wait

echo "==> 3/4 Namespace, DB secret, Gateway and routes"
kubectl apply -f "$REPO_ROOT/k8s/platform/namespace.yaml"
DB_PASSWORD=$(aws ssm get-parameter --region "$REGION" --name "$SSM_DB_PASSWORD" \
  --with-decryption --query Parameter.Value --output text)
kubectl create secret generic db-credentials -n "$NAMESPACE" \
  --from-literal=username=postgres --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASSWORD
kubectl apply -f "$REPO_ROOT/k8s/platform/gateway.yaml" -f "$REPO_ROOT/k8s/platform/httproute.yaml"

echo "==> 4/4 Give GitHub Actions edit access to the $NAMESPACE namespace"
if ! aws eks describe-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
     --principal-arn "$ROLE_ARN" >/dev/null 2>&1; then
  aws eks create-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
    --principal-arn "$ROLE_ARN" >/dev/null
fi
aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces="$NAMESPACE" >/dev/null

echo "==> Done. Gateway status:"
kubectl get gateway -n "$NAMESPACE"