# Support policy

SpaceO is maintained on a best-effort basis. The supported public line is the latest
independently qualified release; older releases and builds from `main` are not guaranteed support.
No qualified public release is currently recorded.

Before requesting help, check the [troubleshooting guide](docs/TROUBLESHOOTING.md), then run
`spaceo version --json` and `spaceo doctor --json`. Search existing
issues, then open a GitHub issue with those outputs after removing usernames, paths, window
titles, application content, and other sensitive data. Include the macOS version/build,
architecture, install method, reproduction steps, expected behavior, and actual behavior.

The package deployment target is macOS 14. Current public-release support is Apple Silicon
(`arm64`) only because that is the only architecture with recorded live qualification.
The release tooling fails closed on other architectures; Intel remains unqualified and unsupported
for public release. Runtime private-API discovery is not a promise that every macOS update or host
configuration will work.
See the [release policy](docs/RELEASE_POLICY.md) and
[private API support notes](docs/PRIVATE_API_SUPPORT.md).

Use public issues for reproducible defects and narrowly scoped feature requests. Questions about
custom deployments, private forks, older versions, or unqualified hosts may not receive a
response. Send suspected vulnerabilities through the private process in
[SECURITY.md](SECURITY.md), never through a public support issue.
