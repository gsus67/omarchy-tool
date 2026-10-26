# Security

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/gsus67/omarchy-tool/security/advisories/new)
instead of a public issue.

Every change runs, in CI:

- static QML checks: every text element renders plain text and the QML
  references no remote URL;
- the backend tests (`tests/run.sh`, `tests/i18n.sh`) in an Arch container,
  against throwaway state that never touches the real system;
- ShellCheck on every script;
- CodeQL `security-extended` analysis of the workflows.
