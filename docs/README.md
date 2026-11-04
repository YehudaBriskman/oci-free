# oci-free manual

How the platform is put together, from the cloud account to the backups. Each
page is generic: it describes what the files do, not a particular deployment's
addresses or credentials.

| Page | Covers |
|---|---|
| [Infrastructure](infrastructure.md) | what OpenTofu creates, the Always Free envelope, the closed-by-default network, the cloud-init bootstrap |
| [Kubernetes](kubernetes.md) | every manifest and Helm values file in `k8s/`, pinned Helm releases, rebuilding the cluster |
| [Deploy](deploy.md) | how the site's CI rolls out to `prod` and `preprod`, the rollout scripts, what CI's credentials can do |
| [Backups](backups.md) | the nightly CouchDB and Forgejo jobs, what they do and do not protect against, restoring |

The architecture diagram is [`readme/architecture.svg`](readme/architecture.svg)
(and a PNG beside it). The decisions behind the setup are written up as notes at
[yehudabriskman.com/blog/area/oci-free](https://yehudabriskman.com/blog/area/oci-free).
