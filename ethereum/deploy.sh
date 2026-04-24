#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Creating namespace..."
kubectl create namespace ethereum --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating genesis configmap..."
kubectl create configmap ethereum-genesis \
  --namespace=ethereum \
  --from-file=genesis.json="$DIR/output/metadata/genesis.json" \
  --from-file=config.yaml="$DIR/output/metadata/config.yaml" \
  --from-file=genesis.ssz.gz="$DIR/output/metadata/genesis.ssz.gz" \
  --from-file=deposit_contract.txt="$DIR/output/metadata/deposit_contract.txt" \
  --from-file=deposit_contract_block.txt="$DIR/output/metadata/deposit_contract_block.txt" \
  --from-file=deposit_contract_block_hash.txt="$DIR/output/metadata/deposit_contract_block_hash.txt" \
  --from-file=bootstrap_nodes.txt="$DIR/output/metadata/bootstrap_nodes.txt" \
  --from-file=genesis_validators_root.txt="$DIR/output/metadata/genesis_validators_root.txt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating JWT secret..."
kubectl create secret generic ethereum-jwt \
  --namespace=ethereum \
  --from-file=jwtsecret="$DIR/output/jwt/jwtsecret" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating validator keys secret..."
kubectl apply -f "$DIR/validator-keys-secret.yaml"

echo "==> Labeling worker01 as bootnode..."
kubectl label node e3vote-worker01 ethereum-role=bootnode --overwrite

echo "==> Stage 1: Deploying bootnode (worker01)..."
kubectl apply -f "$DIR/bootnode.yaml"
echo "    Waiting for bootnode to be ready..."
kubectl rollout status deployment/ethereum-bootnode -n ethereum --timeout=120s

echo "==> Stage 2: Deploying remaining nodes (worker02-08)..."
kubectl apply -f "$DIR/nodes.yaml"

echo "==> Stage 3: Deploying Dora explorer..."
kubectl apply -f "$DIR/dora.yaml"

echo "==> Done. Check status with: kubectl get pods -n ethereum -o wide"
