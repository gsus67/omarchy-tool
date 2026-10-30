# Security

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/gsus67/omarchy-tool/security/advisories/new)
instead of a public issue.

Disk tiles is a user-only Nautilus extension. Its installer records ownership,
does not overwrite existing extensions, restores its bookmark changes and keeps
the cleanup ledger on failure. Capacity reads are asynchronous and cancellable;
the view has no disk-write, mount, eject or format commands. It uses internal
Nautilus widgets, so supported major versions are explicitly gated. See
[the integration and footprint](docs/DISK_TILES.md).

Every change runs, in CI:

- static QML checks: every text element renders plain text and the QML
  references no remote URL;
- the backend tests (`tests/run.sh`, `tests/i18n.sh`) in an Arch container,
  against throwaway state that never touches the real system;
- ShellCheck on every script;
- CodeQL `security-extended` analysis of the workflows.
