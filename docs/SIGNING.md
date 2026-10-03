# Windows code signing

Authenticode signing requires a real code-signing certificate trusted by Windows. A self-signed certificate is useful only for development.

For GitHub Actions, export a password-protected PFX and configure repository secrets:

- `WINDOWS_CERTIFICATE_BASE64`: Base64 content of the PFX;
- `WINDOWS_CERTIFICATE_PASSWORD`: PFX password.

The release workflow signs PowerShell files before packaging, signs both Windows executables, keeps SHA-256 mandatory, and creates a GitHub provenance attestation.

```powershell
Get-AuthenticodeSignature ./RustServerControlCenter-Setup-v12.1.0.exe
Get-FileHash ./RustServerControlCenter-Setup-v12.1.0.exe -Algorithm SHA256
```

For public distribution, use an organization-validation or extended-validation certificate from a recognized certificate authority and protect the private key with the provider’s recommended hardware or cloud signing service.
