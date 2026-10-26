#!/usr/bin/env bash
# Prepares a fresh EKS cluster for the voting app (run once after ./up.sh).
set -euo pipefail

CLUSTER="eks-hilal"
REGION="us-east-1"
NAMESPACE="voting-app"
DOMAIN="hilal.ironlabs.online"
HOSTED_ZONE="ironlabs.online"
NGF_VERSION="2.8.0"
ESO_VERSION="2.14.0"
CERT_MANAGER_VERSION="v1.21.3"
ROLE_ARN="arn:aws:iam::686699774218:role/github-actions-voting-app-hilal"
ESO_ROLE_ARN="arn:aws:iam::686699774218:role/eso-voting-app-hilal"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 1/7 Connect kubectl to the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "==> 2/7 Gateway API CRDs and NGINX Gateway Fabric"
# CRDs are vendored in the repo so the script doesn't depend on GitHub at run time.
# They must match NGF_VERSION. After changing NGF_VERSION, regenerate them:
#   git clone --depth 1 --branch v<NGF_VERSION> https://github.com/nginx/nginx-gateway-fabric /tmp/ngf
#   kubectl kustomize /tmp/ngf/config/crd/gateway-api/standard > k8s/platform/crds/gateway-api.yaml
kubectl apply -f "$REPO_ROOT/k8s/platform/crds/gateway-api.yaml"
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "$NGF_VERSION" --create-namespace -n nginx-gateway --wait

echo "==> 3/7 External Secrets Operator (reads the DB password from SSM)"
# The Pod Identity association must exist before the ESO pods start,
# so the pods get their AWS credentials on first boot.
ASSOCIATIONS=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" \
  --namespace external-secrets --service-account external-secrets \
  --query 'length(associations)' --output text)
if [ "$ASSOCIATIONS" = "0" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER" --region "$REGION" \
    --namespace external-secrets --service-account external-secrets \
    --role-arn "$ESO_ROLE_ARN" >/dev/null
fi
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_VERSION" --create-namespace -n external-secrets --wait

echo "==> 4/7 cert-manager and Let's Encrypt issuers"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" --create-namespace -n cert-manager \
  -f "$REPO_ROOT/k8s/platform/cert-manager-values.yaml" --wait
kubectl apply -f "$REPO_ROOT/k8s/platform/cluster-issuers.yaml"

echo "==> 5/7 Namespace, external secret, Gateway and routes"
kubectl apply -f "$REPO_ROOT/k8s/platform/namespace.yaml"
kubectl apply -f "$REPO_ROOT/k8s/platform/external-secrets.yaml"
kubectl apply -f "$REPO_ROOT/k8s/platform/gateway.yaml" -f "$REPO_ROOT/k8s/platform/httproute.yaml"

echo "==> 6/7 Point $DOMAIN to the Gateway's load balancer"
kubectl wait gateway/voting-gateway -n "$NAMESPACE" --for=condition=Programmed --timeout=300s
LB=$(kubectl get gateway voting-gateway -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}')
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$HOSTED_ZONE" \
  --query 'HostedZones[0].Id' --output text)
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$DOMAIN\", \"Type\": \"CNAME\", \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$LB\"}]
    }
  }]
}" >/dev/null

echo "==> 7/7 Give GitHub Actions edit access to the $NAMESPACE namespace"
if ! aws eks describe-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
     --principal-arn "$ROLE_ARN" >/dev/null 2>&1; then
  aws eks create-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
    --principal-arn "$ROLE_ARN" >/dev/null
fi
aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces="$NAMESPACE" >/dev/null

echo "==> Done. https://$DOMAIN/vote  (the certificate can take 1-3 minutes)"
kubectl get gateway,certificate -n "$NAMESPACE"
kubectl get externalsecret -n "$NAMESPACE"