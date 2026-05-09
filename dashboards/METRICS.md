Given a zero-fee private PoS chain used for e-voting load testing, the metrics that matter fall into a few categories:

Chain health (is the network working?)

- chain_head_block — block height over time. Flat = chain stalled.
- beacon_head_slot — slot progression. Gaps = missed slots.
- beacon_current_justified_epoch / beacon_finalized_epoch — finality. If finalized epoch stops advancing,
  votes on-chain aren't guaranteed permanent.
- p2p_peers (geth) / p2p_peer_count (prysm) — peer connectivity. Drops = network partition risk.

Transaction throughput (can the chain handle the vote load?)

- txpool_pending — pending transactions in the mempool. Sustained growth = chain can't keep up with vote submission
  rate.
- txpool_queued — queued (out-of-nonce-order) transactions. High values = nonce management issues in the voting
- chain_head_gas_used — not available as a native Geth Prometheus metric. Dashboard uses txpool total size
  (pending + queued) as a proxy for transaction throughput pressure.

Consensus reliability (are validators doing their job?)

- beacon_missed_slots or slot gaps — missed block proposals. Critical: a missed slot delays vote inclusion.
- validator_successful_attestations_total / validator_failed_attestations_total — attestation success rate. Low hit rate = consensus
  instability.
- beacon_reorgs_total — chain reorganizations. Reorgs could temporarily "undo" submitted votes before re-inclusion.

Latency (how fast do votes get confirmed?)

- rpc_duration_all (geth) — RPC response times (summary with quantiles, values in nanoseconds). The voting client
  calls eth_sendRawTransaction; if this is slow, vote submission backs up.
- on_block_processing_milliseconds — time to process each block/slot (summary, in milliseconds). High values = blocks
  take long to validate.

Resource pressure (will it survive the load test?)

- chain_head_block rate vs expected (1 block per 2s with your config) — are you keeping up?
- p2p_peer_count (prysm) — beacon peer connectivity under load.

System metrics per node (from OTel hostmetrics receiver)

- system_cpu_time — CPU usage by state (idle, user, system). Grouped by host_name to compare nodes.
- system_cpu_load_average_1m — 1-minute load average per host.
- system_memory_usage — memory by state (used, free, buffered, cached). Spot OOM risk.
- system_disk_io / system_disk_operations — disk bytes and IOPS per device/direction. Chain data writes are the
  bottleneck on slow disks.
- system_network_io — network bytes per direction. Correlate with P2P traffic.
- system_network_errors / system_network_dropped — packet errors and drops. Non-zero = network issues.

Dashboard

The file `e3vote-loadtest-dashboard.json` is a SigNoz-importable dashboard with 9 sections (21 panels):

1. Chain Health — block height, beacon slot, finalized epoch, geth peers
2. Transaction Throughput — txpool pending/queued, gas used
3. Consensus Reliability — attestation hit rate, reorgs
4. Latency — RPC p95 duration, slot processing time
5. Resource Pressure — block production rate, beacon peers
6. System CPU — usage %, load average (per node)
7. System Memory — bytes used, utilization % (per node)
8. System Disk — I/O bytes/s, operations/s (per node)
9. System Network — I/O bytes/s, errors+drops (per node)

All Ethereum panels group by `node` label (from the Prometheus relabeling in signoz-k8s-infra-values.yaml).
All system panels group by `host_name` label (from the OTel hostmetrics receiver).

Import: SigNoz UI → Dashboards → + New Dashboard → Import JSON → paste/upload the file.

What you can skip for this use case:

- Gas price / base fee metrics (all zero, irrelevant)
- Sync metrics (private network, all nodes start from genesis)
- Balance tracking (validators have fixed 32 ETH, not meaningful)
- Blob/shard metrics (not using L2 or blob transactions)

The most important dashboard for your load test would combine: txpool_pending + chain_head_block rate +
beacon_head_slot + missed slots + RPC latency — this tells you at a glance whether the chain is absorbing votes as
fast as they're submitted and whether finality is keeping up.
