# Source check (2026-11-17)

| Source | Claim in pitch | What it says today |
|---|---|---|
| kubernetes/kubernetes#97076 | CVE-2020-8554 still open | OPEN, labels `lifecycle/frozen`, `official-cve-feed`. externalIPs and patching `status.loadBalancer.ingress.ip` both intercept traffic; "no patch"; LB status "should not typically be granted to users". |
| kubernetes/kubernetes#103675 | CVE-2021-25740 Endpoints/EndpointSlice cross-namespace | CLOSED with label `cve/wontfix`. "no patch"; NetworkPolicy that trusts the LB/Ingress cannot prevent exposure. Mitigation: remove Endpoints write from `system:aggregate-to-edit` with `kubectl auth reconcile --remove-extra-permissions`. |
| k8s blog 2026-05-26 "Reconciling unfixed CVEs" | 2026 post on unfixed CVEs | Lists CVE-2021-25740 as will-not-fix; edit/admin lost Endpoints write in 1.22 for *new* clusters; upgraded clusters must audit `system:aggregate-to-edit`. Mentions CVE-2020-8554 as unfixed, affects all versions. |
| k8s blog 2026-05-14 externalIPs deprecation | deprecated in 1.36 | `.spec.externalIPs` deprecated in 1.36 with warnings; kube-proxy drops support v1.40 at the earliest; DenyServiceExternalIPs "you may still want to enable". Also notes MetalLB honours user-requested `loadBalancerIP` "assuming it is available". |
| Admission controllers reference | DenyServiceExternalIPs off by default | It is not in the default-enabled list; it blocks only *new* externalIPs values, existing ones keep working. |
| kubernetes/enhancements#2200 | KEP | "KEP: Block service ExternalIPs via admission", CLOSED, `stage/alpha`. |
