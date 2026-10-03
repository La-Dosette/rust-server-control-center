# Windows and GitHub publishing

## Build

```powershell
./Build-Standalone.ps1 -Version 12.1.0
./Build-SingleExe.ps1 -Version 12.1.0
./Build-WindowsInstaller.ps1 -Version 12.1.0
./scripts/Test-Release.ps1 -PackageRoot ./dist/RustServerControlCenter-Portable-v12.1.0
```

The regular `.exe` is a self-contained launcher. `Setup` reinstalls application files, creates shortcuts, and registers Windows uninstall information while preserving existing worlds.

## Channels and rollback

- `v12.1.0`: stable release;
- `v12.2.0-beta.1`: beta prerelease.

Stable selects GitHub’s latest non-prerelease. Beta accepts the newest published release. Before replacing files, the updater stores every managed file with its size and SHA-256. Global diagnostics can restore an earlier version.

## Checklist

1. Run reliability and first-install tests.
2. Verify the ZIP, launcher, and Setup with `--verify`.
3. Configure the certificate described in [SIGNING.md](SIGNING.md).
4. Push a signed `v*` tag. GitHub Actions builds, optionally signs, attests, and publishes the artifacts.
