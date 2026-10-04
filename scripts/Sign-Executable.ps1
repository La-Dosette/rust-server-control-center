[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$CertificateBase64,
    [Parameter(Mandatory = $true)][string]$CertificatePassword,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -or [IO.Path]::GetExtension($ExecutablePath) -ne '.exe') { throw 'Exécutable Windows introuvable.' }
$CertificateBytes = [Convert]::FromBase64String($CertificateBase64)
$Flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
$Certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($CertificateBytes,$CertificatePassword,$Flags)
try {
    if (-not $Certificate.HasPrivateKey -or $Certificate.NotAfter -le (Get-Date)) { throw 'Certificat de signature absent, incomplet ou expiré.' }
    $Signature = Set-AuthenticodeSignature -LiteralPath $ExecutablePath -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
    if ([string]$Signature.Status -ne 'Valid') { throw "Signature de l’EXE refusée : $($Signature.StatusMessage)" }
    $Verification = Get-AuthenticodeSignature -LiteralPath $ExecutablePath
    if ([string]$Verification.Status -ne 'Valid' -or [string]$Verification.SignerCertificate.Thumbprint -ne [string]$Certificate.Thumbprint) { throw 'La vérification Authenticode après signature a échoué.' }
    $Hash = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(($ExecutablePath + '.sha256'),("$Hash  $([IO.Path]::GetFileName($ExecutablePath))" + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ExecutablePath=$ExecutablePath;Subject=$Certificate.Subject;Thumbprint=$Certificate.Thumbprint;Sha256=$Hash;TimestampServer=$TimestampServer}
}
finally {
    $Certificate.Dispose()
    [Array]::Clear($CertificateBytes,0,$CertificateBytes.Length)
}
