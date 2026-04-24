#!/bin/bash
# Tears down and redeploys the Ethereum PoS private network from scratch.
# Must be run from the ethereum/ directory.
# Genesis timestamp defaults to now — deploy starts immediately after generation.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# === Step 1: Tear down existing chain ===
echo "==> Step 1: Deleting ethereum namespace..."
kubectl delete ns ethereum --wait --timeout=120s 2>/dev/null || echo "    Namespace not found, skipping."

# === Step 2: Generate CL+EL genesis with prysmctl ===
echo "==> Step 2: Generating genesis with prysmctl..."
rm -rf output-prysm && mkdir output-prysm
docker run --rm \
  -v "$DIR/output-prysm:/data" \
  -v "$DIR/config-prysm.yml:/data/config.yml" \
  -v "$DIR/genesis-in.json:/data/genesis-in.json" \
  gcr.io/prysmaticlabs/prysm/cmd/prysmctl:latest \
  testnet generate-genesis \
  --fork=electra \
  --num-validators=8 \
  --chain-config-file=/data/config.yml \
  --geth-genesis-json-in=/data/genesis-in.json \
  --output-ssz=/data/genesis.ssz \
  --geth-genesis-json-out=/data/genesis.json
sudo chown -R "$(id -u):$(id -g)" output-prysm

# === Step 3: Patch EL genesis with blobSchedule (required by geth 1.17) ===
# NOTE: Do NOT modify genesis.json in any other way after prysmctl — the CL
# genesis (genesis.ssz) embeds a hash of the EL state. Any post-hoc change
# (e.g. adding noBaseFee) breaks the EL/CL agreement and blocks won't sync.
echo "==> Step 3: Patching genesis.json with blobSchedule..."
python3 -c "
import json
with open('output-prysm/genesis.json') as f:
    g = json.load(f)
g['config']['blobSchedule'] = {
    'cancun': {'target': 3, 'max': 6, 'baseFeeUpdateFraction': 3338477},
    'prague': {'target': 6, 'max': 9, 'baseFeeUpdateFraction': 5007716}
}
with open('output-prysm/genesis.json', 'w') as f:
    json.dump(g, f, indent=2)
"

# === Step 4: Prepare output directory ===
echo "==> Step 4: Preparing output directory..."
rm -rf output && mkdir -p output/metadata output/jwt
cp output-prysm/genesis.json output/metadata/genesis.json
cp output-prysm/genesis.ssz output/metadata/genesis.ssz
cp config-prysm.yml output/metadata/config.yaml
gzip -k output/metadata/genesis.ssz
openssl rand -hex 32 | tr -d '\n' > output/jwt/jwtsecret
echo "0x4242424242424242424242424242424242424242" > output/metadata/deposit_contract.txt
echo "0" > output/metadata/deposit_contract_block.txt
echo "0x0000000000000000000000000000000000000000000000000000000000000000" > output/metadata/deposit_contract_block_hash.txt
echo "" > output/metadata/bootstrap_nodes.txt
echo "" > output/metadata/genesis_validators_root.txt

# === Step 5: Deploy ===
echo "==> Step 5: Running deploy.sh..."
bash ./deploy.sh

echo ""
echo "==> Redeploy complete. Chain should start producing blocks within ~30s."
echo "    Monitor with: kubectl logs -n ethereum -l role=bootnode -c prysm-beacon --tail=5 -f"
