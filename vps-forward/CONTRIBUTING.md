# Contributing

Contributions are welcome for bug fixes, distribution compatibility, tests, and carefully scoped features.

1. Open an issue for behavior-changing work.
2. Never add real server addresses, credentials, tokens, or user rulesets.
3. Keep all system mutations behind testable wrapper functions.
4. Preserve the ownership boundary: never flush the global ruleset or modify foreign tables.
5. Add tests for every parser, generator, rollback, or installer change.
6. Update both READMEs and CHANGELOG when CLI behavior changes.

Run before submitting:

```bash
bash -n vps-forward.sh lib/vps-forward-core.sh tests/*.sh
sh -n install.sh
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

Commits should be small, imperative, and explain security-relevant tradeoffs.
