# Source check, 2026-11-19

| Source | What it says today | How checked |
|---|---|---|
| kubernetes/kubernetes#20165 "Service Account Key Rotation" | open, created 2016-01-26 | `gh api repos/kubernetes/kubernetes/issues/20165` |
| kubernetes/kubernetes#34029 "Enable service account signing key rotation" | merged 2016-10-11 | `gh api repos/kubernetes/kubernetes/pulls/34029` |
| KEP-740 "Support external signing of service account tokens" (`keps/sig-auth/740-service-account-external-signing/kep.yaml`) | stage `stable`, latest-milestone v1.36; alpha v1.32, beta v1.34, stable v1.36 | `gh api repos/kubernetes/enhancements/contents/...` |

## External signer in Kubernetes v1.37.2 (read from the v1.37.2 tag)

- gRPC API: package `v1`, service `v1.ExternalJWTSigner` with `Sign`, `FetchKeys`, `Metadata`
  (`staging/src/k8s.io/externaljwt/apis/v1/api.proto`). `v1alpha1` is still in the tree, but the
  API server's client (`pkg/serviceaccount/externaljwt/plugin/plugin.go`, `keycache.go`) imports only `v1`.
- Transport: Unix domain socket (`grpc.Dial` with a `unix` dialer).
- Flag: `--service-account-signing-endpoint` (`pkg/controlplane/apiserver/options/options.go`):
  "Path to socket where a external JWT signer is listening. This flag is mutually exclusive with
  --service-account-signing-key-file and --service-account-key-file."
  `pkg/kubeapiserver/options/authentication.go` enforces it: `cannot set mutually exclusive flags
  --service-account-key-file and --service-account-signing-endpoint at the same time`.
- Feature gate `ExternalServiceAccountTokenSigner`: Alpha 1.32 (off), Beta 1.34 (on), GA 1.36
  (on, `LockToDefault: true`) in `pkg/features/kube_features.go`. Nothing to enable on v1.37.2.
- `FetchKeys` keys carry `exclude_from_oidc_discovery` (verification-only keys, "eg: supported keys
  for legacy tokens") and a `refresh_hint_seconds`; `Metadata` returns
  `max_token_expiration_seconds` (must be at least 600 s).

## Kind node image

`kindest/node` on Docker Hub has `v1.37.0` (and `v1.37.0-rc.1`) but no `v1.37.1` or `v1.37.2`.
Kind v0.33.0's release notes list `kindest/node:v1.37.0@sha256:a1ed56cf…` as the default.
