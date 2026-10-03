# Contributing

Rust Server Control Center targets Windows 10/11 with Windows PowerShell 5.1. Keep the vanilla experience usable without Carbon or plugins, and expose game-mode controls only when a compatible plugin is detected.

Before opening a pull request:

```powershell
./scripts/Test-ControlCenterReliability.ps1
./Build-Standalone.ps1 -Version 12.1.0 -OutputRoot ./dist-ci
./scripts/Test-Release.ps1 -PackageRoot ./dist-ci/RustServerControlCenter-Portable-v12.1.0
```

Do not commit server binaries, worlds, maps, logs, RCON passwords, DDNS tokens, public IP addresses, or generated `data` files. Changes to the user interface should include an English entry in `tool/locales/ui-en-US.json` and an updated capture when documentation is affected.
