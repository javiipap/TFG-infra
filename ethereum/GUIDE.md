# How the Ethereum Deployment Works — A Beginner's Guide

This document explains how the private Ethereum network is deployed on Kubernetes, step by step. It assumes no prior Kubernetes knowledge.

## Key Concepts

**Pod**: The smallest unit in Kubernetes. A pod is one or more containers running together on the same machine. They share the same network (can talk via `localhost`).

**Container**: A lightweight, isolated process. Think of it as a mini virtual machine running a single application. Our pods have three containers: geth, prysm-beacon, and prysm-validator.

**Node**: A physical or virtual machine in the cluster. We have 9 nodes: 1 control plane (manages the cluster) and 8 workers (run our workloads).

**DaemonSet**: Ensures exactly one pod runs on each matching node. We use this to run an Ethereum node on every worker.

**Deployment**: Runs a specified number of pod replicas. We use this for the bootnode (1 replica on a specific worker).

**Service**: A stable network address for reaching pods. Pods come and go (they get new IPs when restarted), but a Service provides a fixed DNS name and IP.

**ConfigMap**: Stores configuration files that pods can read. We use it for genesis files.

**Secret**: Like a ConfigMap, but for sensitive data. We use it for the JWT token and validator keys.

**Init Container**: A container that runs before the main containers start. Used for setup tasks. The pod won't start its main containers until all init containers finish successfully.

**Namespace**: A way to organize resources. All our Ethereum resources live in the `ethereum` namespace.

---

## What Gets Deployed

```
Cluster overview:

  Control Plane (e3vote-cp)
  └── Manages the cluster, no Ethereum workloads

  Worker01 (bootnode)
  └── Pod: geth + prysm-beacon + prysm-validator (starts first, others connect to it)

  Worker02–08 (peers)
  └── Pod: geth + prysm-beacon + prysm-validator (connect to bootnode on startup)
```

Each worker runs one pod containing:
- **geth**: The Ethereum execution client. Processes transactions, maintains the blockchain state.
- **prysm-beacon**: The Ethereum consensus client. Manages proof-of-stake consensus, proposes and validates blocks.
- **prysm-validator**: Signs attestations and block proposals using the node's validator key.

These containers talk to each other inside the pod via `localhost` — geth↔beacon on port 8551 (JWT auth), validator↔beacon on port 4000 (gRPC).

---

## The Deployment Process

### Stage 0: Genesis Generation (your machine)

Before anything runs on the cluster, we generate the "genesis" — the initial state of the blockchain. This includes:

1. **genesis.json** — Defines the execution layer starting state (chain ID, prefunded accounts, system contracts)
2. **genesis.ssz** — Defines the consensus layer starting state (initial validators, beacon chain config)
3. **config.yaml** — Beacon chain parameters (slot duration, fork versions)
4. **Validator keys** — Prysm interop keys (derived deterministically, no keystores needed)
5. **JWT secret** — A shared password for geth↔prysm communication

The genesis timestamp must be set to a few minutes in the future. The chain starts producing blocks once this time is reached.

### Stage 1: Bootnode (worker01)

```
deploy.sh runs:
  kubectl apply -f bootnode.yaml
  kubectl rollout status ... (waits until ready)
```

What happens inside the bootnode pod:

```
1. init-genesis container:
   - Copies genesis files from ConfigMap to a shared directory
   - Decompresses genesis.ssz.gz (it was compressed to fit in a ConfigMap)

2. init-geth container:
   - Runs "geth init" to initialize the blockchain database from genesis.json
   - Skips if already initialized (idempotent)

3. Main containers start:
   - geth starts, listens for peers on port 30303
   - prysm-beacon starts, listens for peers on ports 13000/12000
   - prysm-validator starts, connects to local beacon on port 4000
   - geth and prysm-beacon connect via localhost:8551
```

A **ClusterIP Service** (`ethereum-bootnode`) is created pointing to this pod. This gives it a stable DNS name: `ethereum-bootnode.ethereum.svc.cluster.local`.

### Stage 2: Peer Nodes (worker02–08)

```
deploy.sh runs:
  kubectl apply -f nodes.yaml
```

The DaemonSet creates one pod on each of worker02 through worker08. Each pod goes through:

```
1. init-genesis: Same as bootnode — copies and decompresses genesis files

2. init-geth: Same as bootnode — initializes geth database

3. init-bootnode:
   - Calls the bootnode's prysm API to get its ENR (a peer address)
   - Calls the bootnode's geth API to get its enode (another peer address)
   - Derives the validator index from the node name (e.g. worker05 → index 4)
   - Saves all to shared directories

4. init-wrapper:
   - Creates shell wrapper scripts for prysm (which uses distroless images with no shell)
   - Copies busybox for use inside distroless containers

5. Main containers start:
   - geth starts with --bootnodes=<bootnode enode> → connects to bootnode
   - prysm-beacon starts with --bootstrap-node=<bootnode ENR> → connects to bootnode
   - prysm-validator starts with --interop-start-index=<N> → uses the correct key
   - Through the bootnode, they discover all other peers
```

---

## Networking

### Inside the cluster

```
Pod-to-pod communication (automatic via Kubernetes networking):

  geth (worker02) ←──P2P port 30303──→ geth (worker01/bootnode)
  prysm-beacon (worker02) ←──P2P port 13000/12000──→ prysm-beacon (worker01/bootnode)

Inside each pod:
  geth ←──Engine API, localhost:8551, JWT auth──→ prysm-beacon
  prysm-validator ──gRPC, localhost:4000──→ prysm-beacon
```

### Services

| Service | Type | Purpose |
|---------|------|---------|
| `ethereum-bootnode` | ClusterIP | Internal: lets peer nodes find the bootnode by DNS name |
| `ethereum-rpc` | NodePort (30545/30546) | External: exposes geth JSON-RPC and WebSocket to the outside world |

**ClusterIP**: Only reachable from inside the cluster. Used for internal communication.

**NodePort**: Opens a port on every node's IP. Reachable from outside the cluster. When you hit `http://10.6.5.80:30545`, Kubernetes routes it to one of the geth pods.

---

## How Peer Discovery Works

Ethereum nodes need to find each other to form a network. On the public Ethereum network, there are well-known bootnodes. On our private network, we create our own:

1. **Worker01 starts first** as the bootnode. It doesn't know any peers yet — it just listens.
2. **Worker02–08 start next**. Their init containers ask the bootnode "what's your address?" via the Kubernetes service.
3. Each peer node starts geth and prysm-beacon with the bootnode's address as a `--bootnodes` / `--bootstrap-node` flag.
4. Once connected to the bootnode, nodes exchange peer lists and discover each other. After a few seconds, every node knows about all 7 others.

---

## How Blocks Are Produced

Once the genesis timestamp is reached:

1. Prysm assigns a validator to propose a block for each slot
2. The assigned prysm-validator tells its local geth to build an execution payload (transactions)
3. Geth returns the payload, prysm wraps it in a beacon block
4. The block is broadcast to all peers
5. Other validators attest (vote) that the block is valid
6. After enough attestations, the block is finalized

With 8 validators and 12-second slots, each validator proposes roughly every 96 seconds.

---

## File Overview

```
ethereum/
├── values.env                  # Genesis parameters (edit before generating)
├── config-prysm.yml            # Prysm chain config (slot duration, fork versions)
├── genesis-in.json             # Prefunded accounts (input to prysmctl)
├── deploy.sh                   # Runs the two-stage deployment
├── redeploy.sh                 # Tears down and redeploys from scratch
├── bootnode.yaml               # Kubernetes manifest for worker01
├── nodes.yaml                  # Kubernetes manifest for worker02-08
├── dora.yaml                   # Blockchain explorer (optional)
└── output/                     # Generated by prysmctl + deploy scripts
    ├── metadata/
    │   ├── genesis.json        # Execution layer genesis
    │   ├── genesis.ssz(.gz)    # Consensus layer genesis
    │   └── config.yaml         # Beacon chain config
    └── jwt/jwtsecret           # Shared auth token
```
