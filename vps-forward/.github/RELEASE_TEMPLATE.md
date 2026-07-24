## vX.Y.Z

### What changed

-

### Security and compatibility

- Supported: Ubuntu, Debian, Alpine Linux
- Configuration schema:
- nftables compatibility notes:

### Upgrade

```bash
sudo vps-forward backup
# Download the fixed release and verify its SHA256.
sudo ./install.sh
sudo vps-forward check
sudo vps-forward apply
```

### Validation

- [ ] `bash -n` / `sh -n`
- [ ] ShellCheck
- [ ] automated tests
- [ ] clean install on Ubuntu
- [ ] clean install on Debian
- [ ] clean install on Alpine
- [ ] release archive SHA256 attached

### Checksums

Attach `vps-forward-vX.Y.Z.tar.gz.sha256` generated from the final release archive.
