# Security Policy

## Supported versions

Only the latest tagged release receives security fixes before 1.0.

## Reporting a vulnerability

Do not open a public issue for a suspected command-injection, privilege-escalation, unsafe file-operation, or firewall-bypass vulnerability. Use GitHub's private security advisory feature for this repository and include:

- affected version and operating system;
- exact command/configuration needed to reproduce;
- expected and actual nftables transaction;
- impact and any proposed mitigation.

Never include production IP addresses, credentials, tokens, or complete private rulesets. Maintainers should acknowledge a report within seven days. No bounty or fixed disclosure deadline is promised.

## Operational safety

Run fixed, reviewed releases as root. Keep console access before applying firewall changes. `doctor` is a diagnostic aid, not proof that all third-party firewall policy is compatible.
