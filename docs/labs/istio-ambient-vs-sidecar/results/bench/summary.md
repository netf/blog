### fixed: latency in ms, median of 3 rounds (min-max)

| mode | achieved rps | p50 | p90 | p99 | p99.9 | non-200 |
|---|---|---|---|---|---|---|
| baseline | 1000 (1000-1000) | 0.23 (0.22-0.23) | 0.34 (0.34-0.35) | 0.56 (0.53-0.56) | 1.63 (1.35-3.18) | 0 |
| sidecar | 1000 (1000-1000) | 1.63 (1.52-1.69) | 2.00 (1.89-2.32) | 2.59 (2.48-3.44) | 5.73 (5.17-7.05) | 0 |
| ambient | 1000 (1000-1000) | 0.62 (0.61-0.64) | 0.89 (0.87-0.91) | 1.38 (1.30-1.39) | 2.34 (1.89-3.29) | 0 |
| ambient-wp | 1000 (1000-1000) | 1.90 (1.86-1.92) | 2.41 (2.38-2.43) | 2.92 (2.91-2.99) | 5.07 (4.35-5.65) | 0 | 

### fixed: CPU in cores during the run, median of rounds

| mode | data-plane cores | breakdown | dp millicores per 1k rps | app (client+server) cores | both worker nodes, total cores |
|---|---|---|---|---|---|
| baseline | 0.000 | - | 0 | 0.081 | 0.142 |
| sidecar | 0.206 | sidecar-client 0.106, sidecar-server 0.100 | 206 | 0.076 | 0.337 |
| ambient | 0.077 | ztunnel-worker 0.041, ztunnel-worker2 0.036 | 77 | 0.076 | 0.209 |
| ambient-wp | 0.156 | waypoint 0.088, ztunnel-worker 0.038, ztunnel-worker2 0.029 | 156 | 0.074 | 0.284 | 

### fixed: data-plane working set at end of run (MiB), median of rounds

| mode | containers |
|---|---|
| baseline | - |
| sidecar | sidecar-client 27.5, sidecar-server 27.9 |
| ambient | ztunnel-worker 6.0, ztunnel-worker2 5.9 |
| ambient-wp | waypoint 93.1, ztunnel-worker 6.1, ztunnel-worker2 6.0 | 

### max: latency in ms, median of 3 rounds (min-max)

| mode | achieved rps | p50 | p90 | p99 | p99.9 | non-200 |
|---|---|---|---|---|---|---|
| baseline | 103210 (87228-108184) | 0.11 (0.11-0.13) | 0.28 (0.26-0.33) | 0.92 (0.87-1.19) | 2.97 (2.94-3.63) | 0 |
| sidecar | 11529 (10086-11695) | 1.29 (1.26-1.46) | 2.19 (2.14-2.49) | 3.45 (3.43-4.08) | 5.76 (5.42-6.69) | 0 |
| ambient | 40962 (34054-41505) | 0.35 (0.35-0.41) | 0.59 (0.59-0.75) | 1.22 (1.20-1.49) | 3.10 (3.03-3.66) | 0 |
| ambient-wp | 12932 (11753-13909) | 1.15 (1.09-1.23) | 1.76 (1.59-1.98) | 2.82 (2.37-3.63) | 5.06 (4.24-7.56) | 0 | 

### max: CPU in cores during the run, median of rounds

| mode | data-plane cores | breakdown | dp millicores per 1k rps | app (client+server) cores | both worker nodes, total cores |
|---|---|---|---|---|---|
| baseline | 0.000 | - | 0 | 2.930 | 2.988 |
| sidecar | 2.133 | sidecar-client 1.057, sidecar-server 1.076 | 186 | 0.638 | 2.821 |
| ambient | 1.628 | ztunnel-worker 0.807, ztunnel-worker2 0.821 | 40 | 1.248 | 2.936 |
| ambient-wp | 1.570 | waypoint 0.857, ztunnel-worker 0.374, ztunnel-worker2 0.337 | 121 | 0.623 | 2.269 | 

### max: data-plane working set at end of run (MiB), median of rounds

| mode | containers |
|---|---|
| baseline | - |
| sidecar | sidecar-client 27.7, sidecar-server 28.2 |
| ambient | ztunnel-worker 6.3, ztunnel-worker2 6.1 |
| ambient-wp | waypoint 93.2, ztunnel-worker 6.3, ztunnel-worker2 6.0 | 

### noka: latency in ms, median of 3 rounds (min-max)

| mode | achieved rps | p50 | p90 | p99 | p99.9 | non-200 |
|---|---|---|---|---|---|---|
| baseline | 200 (200-200) | 0.82 (0.76-0.85) | 1.05 (0.98-1.15) | 1.58 (1.32-1.68) | 7.50 (2.50-7.75) | 0 |
| sidecar | 200 (200-200) | 1.80 (1.69-1.85) | 2.35 (2.17-2.38) | 2.93 (2.64-2.96) | 5.50 (3.80-5.73) | 0 |
| ambient | 200 (200-200) | 1.34 (1.27-1.37) | 1.78 (1.70-1.79) | 2.44 (2.39-2.45) | 4.43 (3.67-4.75) | 0 |
| ambient-wp | 200 (200-200) | 2.38 (2.37-2.40) | 2.96 (2.95-3.01) | 3.71 (3.50-3.78) | 6.00 (4.40-8.00) | 0 | 

### noka: CPU in cores during the run, median of rounds

| mode | data-plane cores | breakdown | dp millicores per 1k rps | app (client+server) cores | both worker nodes, total cores |
|---|---|---|---|---|---|
| baseline | 0.000 | - | 0 | 0.096 | 0.167 |
| sidecar | 0.111 | sidecar-client 0.064, sidecar-server 0.047 | 557 | 0.077 | 0.253 |
| ambient | 0.113 | ztunnel-worker 0.059, ztunnel-worker2 0.054 | 566 | 0.083 | 0.287 |
| ambient-wp | 0.130 | waypoint 0.065, ztunnel-worker 0.052, ztunnel-worker2 0.013 | 651 | 0.074 | 0.284 | 

### noka: data-plane working set at end of run (MiB), median of rounds

| mode | containers |
|---|---|
| baseline | - |
| sidecar | sidecar-client 29.2, sidecar-server 28.1 |
| ambient | ztunnel-worker 6.9, ztunnel-worker2 5.8 |
| ambient-wp | waypoint 93.0, ztunnel-worker 7.2, ztunnel-worker2 5.8 | 

