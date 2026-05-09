# e3vote Infrastructure — Deployment Guide

## Overview

This guide covers the deployment of services on a k3s cluster (1 control plane + 8 workers) running on Ubuntu 24.04 at ULL.

### Cluster Nodes

| Node                        | Role          | IP        |
| --------------------------- | ------------- | --------- |
| e3vote-cp.iaas.ull.es       | Control plane | 10.6.5.76 |
| e3vote-worker01.iaas.ull.es | Worker        | 10.6.5.77 |
| e3vote-worker02.iaas.ull.es | Worker        | 10.6.5.78 |
| e3vote-worker03.iaas.ull.es | Worker        | 10.6.5.79 |
| e3vote-worker04.iaas.ull.es | Worker        | 10.6.5.80 |
| e3vote-worker05.iaas.ull.es | Worker        | 10.6.5.81 |
| e3vote-worker06.iaas.ull.es | Worker        | 10.6.5.82 |
| e3vote-worker07.iaas.ull.es | Worker        | 10.6.5.83 |
| e3vote-worker08.iaas.ull.es | Worker        | 10.6.5.84 |

### Prerequisites

- Ansible installed locally with SSH access to all nodes (user: `ansible`, key: `~/.ssh/ansible`)
- `kubectl` configured to access the cluster
- `helm` v3 installed

---

## 1. k3s Cluster Provisioning

The cluster is provisioned using [k3s-ansible](../k3s-ansible/). See its own README for details.

```bash
cd ../k3s-ansible
ansible-playbook playbooks/site.yml -i inventory.yml
```

---

## 2. Container Registry

An in-cluster Docker registry is deployed to host custom images (e.g. the custom geth fork). It runs as a Deployment with a PersistentVolumeClaim and is exposed via NodePort 8080.

k3s on all nodes is configured to pull from this registry over HTTP (no TLS).

### Deploy the registry

```bash
kubectl apply -f registry.yaml
```

### Configure k3s to trust the registry

This distributes `/etc/rancher/k3s/registries.yaml` to all nodes and restarts k3s/k3s-agent:

```bash
cd ../k3s-ansible
ansible-playbook playbooks/registry-config.yml -i inventory.yml
```

The registries config tells containerd to use HTTP when pulling from `e3vote-cp.iaas.ull.es:8080`.

### Pushing images

From any machine that can reach the control plane:

```bash
# Configure Docker to allow insecure registry (one-time)
# Add to /etc/docker/daemon.json:
#   { "insecure-registries": ["e3vote-cp.iaas.ull.es:8080"] }
# Then: sudo systemctl restart docker

# Build and push
docker build -t e3vote-cp.iaas.ull.es:8080/my-image:latest .
docker push e3vote-cp.iaas.ull.es:8080/my-image:latest
```

### Files

- `registry.yaml` — Namespace, PVC, Deployment, NodePort Service
- `../k3s-ansible/playbooks/registry-config.yml` — Ansible playbook to distribute registries.yaml

---

## 3. Monitoring (SigNoz + OpenTelemetry)

Monitoring uses a split architecture:

- **SigNoz server** runs externally (Docker Compose) — handles storage (ClickHouse), query service, and the web UI
- **OpenTelemetry collectors** run inside the cluster (Helm chart) — collect and ship metrics, logs, and traces

### 3.1 Deploy SigNoz server (external machine)

```bash
git clone -b main https://github.com/SigNoz/signoz.git && cd signoz/deploy/docker
docker compose up -d --remove-orphans
```

This starts ClickHouse, the SigNoz query service, the web UI, and an OTel collector that receives data.

Ports on the SigNoz machine:

- `4317` — OTel gRPC receiver (collectors send data here)
- `4318` — OTel HTTP receiver
- `8080` — SigNoz web UI

> **Note:** If the cluster cannot reach the SigNoz machine directly, set up port forwarding. In our case, external port 8080 forwards to internal port 4317 (gRPC) on the SigNoz machine.

### 3.2 Deploy OTel collectors in the cluster

Edit `signoz-k8s-infra-values.yaml` and set `otelCollectorEndpoint` to the SigNoz server's reachable address and gRPC port.

```bash
# Add the Helm repo
helm repo add signoz https://charts.signoz.io
helm repo update

# Install
helm install signoz-k8s-infra signoz/k8s-infra -f signoz-k8s-infra-values.yaml

# To update after changing values
helm upgrade signoz-k8s-infra signoz/k8s-infra -f signoz-k8s-infra-values.yaml
```

This deploys:

- **otelAgent** (DaemonSet, 1 per node) — collects host metrics, kubelet metrics, container logs, and scrapes Ethereum metrics
- **otelDeployment** (single pod) — collects cluster-level metrics and Kubernetes events

### 3.3 Ethereum metrics scraping

The `presets.prometheus` section in `signoz-k8s-infra-values.yaml` configures the OTel agents to scrape Prometheus-format metrics from each Ethereum pod. Three custom scrape jobs target the metrics endpoints:

| Job                  | Container       | Port | Metrics                                              |
| -------------------- | --------------- | ---- | ---------------------------------------------------- |
| `ethereum-geth`      | geth            | 6060 | EL: peers, txpool, chain head, RPC latency, DB stats |
| `ethereum-beacon`    | prysm-beacon    | 6061 | CL: slot processing, attestations, sync status, P2P  |
| `ethereum-validator` | prysm-validator | 6062 | Validator: proposals, attestations, balance tracking |

Each OTel agent uses a node-affinity relabel rule (`__meta_kubernetes_pod_node_name` = `${env:K8S_NODE_NAME}`) to scrape only the Ethereum pod on its own node. This avoids duplicate metrics and cross-node traffic.

### 3.4 Verify

```bash
# Check all collector pods are running
kubectl get pods -l app.kubernetes.io/instance=signoz-k8s-infra

# Check for export errors
kubectl logs -l app.kubernetes.io/component=otel-agent --tail=5
```

Then open the SigNoz UI and check the Infrastructure Monitoring and Logs sections.

### Files

- `signoz-k8s-infra-values.yaml` — Helm values for the k8s-infra chart

---

## 4. Ethereum PoS Private Network

A private Proof of Stake Ethereum network for load testing the e-voting protocol.

- Chain ID: 32382
- Validators: 8 (1 per worker node, using Prysm interop keys)
- Prefunded accounts: 2 (with known private keys, see below)
- Consensus: PoS (Electra/Prague fork from genesis)
- Slot duration: 2s (configurable in `config-prysm.yml`)
- Slots per epoch: 8
- Geth: custom fork v1.17 from the in-cluster registry (`e3vote-cp.iaas.ull.es:8080/custom-geth`)
- Prysm: `latest` (beacon-chain + validator)

### 4.1 Genesis generation

Genesis must be regenerated when redeploying from scratch. The genesis timestamp defaults to the current time, so deploy immediately after generating.

We use `prysmctl` to generate genesis — this ensures the genesis validators match Prysm's interop key derivation. The generated `genesis.json` is then patched with `blobSchedule` for geth 1.17 compatibility.

```bash
cd ~/ull/tfg/infra/deployment/ethereum

# Pull prysmctl (one-time)
docker pull gcr.io/prysmaticlabs/prysm/cmd/prysmctl:latest

# Generate genesis (timestamp defaults to now — deploy immediately after)
rm -rf output-prysm && mkdir output-prysm
docker run --rm \
  -v $PWD/output-prysm:/data \
  -v $PWD/config-prysm.yml:/data/config.yml \
  -v $PWD/genesis-in.json:/data/genesis-in.json \
  gcr.io/prysmaticlabs/prysm/cmd/prysmctl:latest \
  testnet generate-genesis \
  --fork=electra \
  --num-validators=8 \
  --chain-config-file=/data/config.yml \
  --geth-genesis-json-in=/data/genesis-in.json \
  --output-ssz=/data/genesis.ssz \
  --geth-genesis-json-out=/data/genesis.json

# Fix permissions
sudo chown -R $(id -u):$(id -g) output-prysm

# Patch genesis.json with blobSchedule (required by geth 1.17)
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

# Prepare output directory
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
```

> **Important**: Deploy immediately after generating — the genesis timestamp is set to the current time.

### 4.2 Deploy the network

```bash
# Delete previous deployment if exists
kubectl delete ns ethereum --wait

# Deploy (genesis + bootnode + peers + dora)
cd ethereum/
./deploy.sh
```

`deploy.sh` does the following:

1. Creates the `ethereum` namespace, ConfigMap (genesis files), and JWT secret
2. Labels worker01 as the bootnode
3. **Stage 1**: Deploys `bootnode.yaml` — a single Deployment on worker01 with a ClusterIP service, waits for ready
4. **Stage 2**: Deploys `nodes.yaml` — a DaemonSet on worker02-08, each pod has an init container that fetches the bootnode's ENR and enode before starting
5. **Stage 3**: Deploys `dora.yaml` — blockchain explorer on the control plane

Each pod runs 3 containers:

- **geth** (custom fork v1.17) — execution layer
- **prysm-beacon** — consensus layer (beacon node)
- **prysm-validator** — block proposer (uses `--interop-num-validators=1 --interop-start-index=N`)

### 4.3 Verify

```bash
# Check pods (1 bootnode + 7 peers + 1 dora = 9 total)
kubectl get pods -n ethereum -o wide

# Check block production (bootnode)
kubectl logs -n ethereum -l role=bootnode -c prysm-beacon --tail=5

# Check geth peer count (should be 7)
kubectl logs -n ethereum -l role=bootnode -c geth --tail=5

# Query block number via RPC
curl -s http://localhost:30545 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### 4.4 Prefunded accounts

Two accounts are prefunded in `genesis-in.json` with known private keys:

| Address                                      | Private Key                                                          |
| -------------------------------------------- | -------------------------------------------------------------------- |
| `0x123463a4b065722e99115d6c222f267d9cabb524` | `0x2e0834786285daccd064ca17f1654f67b4aef298acbb82cef9ec422fb4975622` |
| `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |

### 4.5 Architecture

```
                    ┌───────────────────────────────────┐
                    │  worker01 (bootnode)              │
                    │  Deployment + ClusterIP svc       │
                    │  ┌────────┬────────┬───────────┐  │
                    │  │  geth  │ prysm  │  prysm    │  │
                    │  │  (EL)  │ beacon │  validator│  │
                    │  └────────┴────────┴───────────┘  │
                    └──────────────┬────────────────────┘
                                   │ ENR / enode
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                     ▼
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │ worker02 (peer)  │ │ worker03 (peer)  │ │  ... worker08    │
   │ DaemonSet        │ │ DaemonSet        │ │  DaemonSet       │
   │ ┌────┬────┬────┐ │ │ ┌────┬────┬────┐ │ │ ┌────┬────┬────┐ │
   │ │geth│bcon│vald│ │ │ │geth│bcon│vald│ │ │ │geth│bcon│vald│ │
   │ └────┴────┴────┘ │ │ └────┴────┴────┘ │ │ └────┴────┴────┘ │
   └──────────────────┘ └──────────────────┘ └──────────────────┘

   Control plane: Dora explorer (port 8081)

Per pod (3 containers):
  geth ◄──Engine API (JWT, localhost:8551)──► prysm-beacon
  prysm-validator ──► prysm-beacon (localhost:4000)

  geth:            :8545 RPC, :8546 WS, :30303 P2P
  prysm-beacon:    :4000 gRPC, :3500 HTTP, :13000/12000 P2P
  prysm-validator: connects to local beacon
```

### Files

- `ethereum/config-prysm.yml` — Prysm chain config (slot duration, fork versions)
- `ethereum/genesis-in.json` — Prefunded accounts (input to prysmctl)
- `ethereum/output/` — Generated genesis files and JWT
- `ethereum/bootnode.yaml` — Bootnode Deployment + ClusterIP service (worker01)
- `ethereum/nodes.yaml` — Peer DaemonSet + NodePort service (worker02-08)
- `ethereum/dora.yaml` — Blockchain explorer
- `ethereum/deploy.sh` — Three-stage deployment script
- `ethereum/SPEC.md` — Full network specification
- `ethereum/GUIDE.md` — Beginner-friendly deployment guide

### NodePort traffic routing

The `ethereum-rpc` NodePort service (30545/30546) load-balances across all geth pods. This means hitting any node's IP may route to any geth pod, not necessarily the local one.

To pin traffic to the local node's pod, add `externalTrafficPolicy: Local` to the service spec. With this setting, traffic on a node's IP only reaches the geth pod on that same node (and is refused on nodes without a geth pod, e.g. the control plane).

---

## 5. Blockchain Explorer (Dora)

[Dora](https://github.com/ethpandaops/dora) is a lightweight beaconchain explorer that provides a web UI to visualize slots, validators, and chain state. It runs on the control plane and connects to the Ethereum nodes via internal ClusterIP services.

Dora is deployed automatically as part of `deploy.sh` (Stage 3). To deploy separately:

```bash
kubectl apply -f ethereum/dora.yaml
```

### Access

Open `http://<any-node-ip>:8081` in your browser (e.g. `http://10.6.5.76:8081`).

### Files

- `ethereum/dora.yaml` — Deployment, ConfigMap, and Services

---

## Directory Structure

```
deployment/
├── README.md                       # This file
├── registry.yaml                   # In-cluster container registry
├── signoz-k8s-infra-values.yaml    # OTel collector Helm values
└── ethereum/
    ├── SPEC.md                     # Ethereum PoS network specification
    ├── GUIDE.md                    # Beginner-friendly deployment guide
    ├── config-prysm.yml            # Prysm chain config
    ├── genesis-in.json             # Prefunded accounts for genesis
    ├── deploy.sh                   # Three-stage deployment script
    ├── bootnode.yaml               # Bootnode Deployment + ClusterIP service
    ├── nodes.yaml                  # Peer DaemonSet + NodePort service
    ├── dora.yaml                   # Blockchain explorer
    └── output/                     # Generated genesis (not committed)
        ├── metadata/
        │   ├── genesis.json        # Geth genesis (patched with blobSchedule)
        │   ├── genesis.ssz(.gz)    # Prysm genesis (compressed for ConfigMap)
        │   └── config.yaml         # Beacon chain config
        └── jwt/jwtsecret           # Shared JWT secret

../k3s-ansible/
├── inventory.yml                   # Cluster inventory (includes registries config)
└── playbooks/
    ├── site.yml                    # Full k3s provisioning
    ├── registry-config.yml         # Distribute registries.yaml to all nodes
    └── registry-hosts.yml          # (cleanup) Remove old /etc/hosts entries
```
