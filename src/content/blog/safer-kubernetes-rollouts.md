---
title: 'Safer Kubernetes rollouts with three boring settings'
description: 'Readiness probes, a sane rolling update strategy and a PodDisruptionBudget prevent most self-inflicted outages.'
pubDate: 2026-09-28
tags: ['kubernetes', 'reliability']
---

Most rollout incidents I have debugged were not exotic. They came from a Deployment missing one of
three settings that take five minutes to add.

## 1. A readiness probe that means something

Without a readiness probe, Kubernetes sends traffic to a pod the moment the container starts. Point
the probe at an endpoint that checks the app can actually serve requests.

```yaml
readinessProbe:
  httpGet:
    path: /healthz/ready
    port: http
  periodSeconds: 5
  failureThreshold: 3
```

## 2. A rolling update that never drops capacity

`maxUnavailable: 0` makes Kubernetes bring up a new pod and wait for it to become ready before
taking an old one away.

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 0
```

## 3. A PodDisruptionBudget

Node drains during cluster upgrades are voluntary disruptions. A PDB stops them from evicting all of
your replicas at once.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api
```

## Enforce it, do not just document it

Put these defaults in your service template and back them with a policy check in CI so nobody has to
remember them:

```bash
kubectl apply --dry-run=server -f deploy/ && conftest test deploy/
```

Boring settings, fewer pages.
