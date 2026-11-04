# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** That includes a
credential you think was committed: report it privately so it can be rotated
before it is discussed.

Report it through GitHub:
[**Report a vulnerability**](https://github.com/YehudaBriskman/oci-free/security/advisories/new)
(the repository's **Security** tab, then **Report a vulnerability**). That
opens a private security advisory that only you and the maintainer can see.

Please include what you found, the file and line, and what an attacker could do
with it.

## What to expect

This is a personal project maintained by one person, so there is no formal
SLA. You can expect an acknowledgement within a few days, and a fix or a
mitigation as soon as is practical for anything that puts the running cluster
at risk. You will be credited in the advisory unless you would rather not be.

## Scope

In scope: the manifests, Helm values, scripts and OpenTofu configuration in
this repository.

Out of scope: scanning, load testing or attacking the live deployment, social
engineering, and vulnerabilities in upstream projects (k3s, Traefik, the Helm
charts), which belong with those projects.

## Supported versions

Only `main`, which is what the cluster runs.
