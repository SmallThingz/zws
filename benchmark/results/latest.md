# WebSocket Benchmark Snapshot

Source: `benchmark/results/latest.json`

Config: host=`127.0.0.1` path=`/` rounds=2 single_conns=1 multi_conns=16 iters=200000 warmup=10000 pipeline_depth=8 msg_size=16 bench_timeout_ms=120000 zws_deadline_ms=30000 uws_deadline_ms=30000

| Suite | zws-sync | zws-sync+dl | zws-async | zws-async+dl | uWS-sync | uWS-sync+dl | uWS-async | uWS-async+dl |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| single / non-pipelined | 158028.21 | 162607.50 | 85592.14 | 94520.45 | 148719.29 | 161160.58 | 133463.68 | 140262.99 |
| single / pipelined | 436208.05 | 385857.99 | 167178.73 | 164686.41 | 893497.65 | 1327791.61 | 404093.60 | 441111.57 |
| multi / non-pipelined | 837004.55 | 885113.28 | 405747.09 | 392415.41 | 424344.27 | 418441.23 | 368187.79 | 363019.57 |
| multi / pipelined | 1598433.93 | 1261822.34 | 669832.49 | 643594.57 | 3115943.87 | 3011907.81 | 542525.31 | 551853.19 |

Fairness notes: all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.
