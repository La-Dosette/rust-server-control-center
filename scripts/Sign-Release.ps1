[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$CertificateBase64,
    [Parameter(Mandatory = $true)][string]$CertificatePassword,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "Package introuvable : $PackageRoot" }
$ManifestPath = Join-Path $PackageRoot 'release-manifest.json'
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'release-manifest.json est absent.' }

$CertificateBytes = [Convert]::FromBase64String($CertificateBase64)
$Flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
$Certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($CertificateBytes,$CertificatePassword,$Flags)
try {
    if (-not $Certificate.HasPrivateKey) { throw 'Le certificat de signature ne contient pas de clé privée.' }
    if ($Certificate.NotAfter -le (Get-Date)) { throw 'Le certificat de signature est expiré.' }
    $Scripts = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | Where-Object Extension -in @('.ps1','.psm1','.psd1'))
    foreach ($Script in $Scripts) {
        $Signature = Set-AuthenticodeSignature -LiteralPath $Script.FullName -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
        if ([string]$Signature.Status -ne 'Valid') { throw "Signature refusée pour $($Script.FullName) : $($Signature.StatusMessage)" }
    }

    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($Entry in @($Manifest.files)) {
        $FilePath = Join-Path $PackageRoot ([string]$Entry.path).Replace('/','\')
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Fichier du manifeste absent : $($Entry.path)" }
        $File = Get-Item -LiteralPath $FilePath
        $Entry.length = [long]$File.Length
        $Entry.sha256 = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $Manifest | Add-Member signing ([pscustomobject]@{ type='Authenticode'; subject=$Certificate.Subject; thumbprint=$Certificate.Thumbprint; timestampServer=$TimestampServer; signedFiles=$Scripts.Count }) -Force
    [IO.File]::WriteAllText($ManifestPath,($Manifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))

    $ZipPath = $PackageRoot + '.zip'
    $ChecksumPath = $ZipPath + '.sha256'
    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) { [IO.File]::Delete($ZipPath) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot,$ZipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
    $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($ChecksumPath,("$Hash  $([IO.Path]::GetFileName($ZipPath))" + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ SignedFiles=$Scripts.Count; Subject=$Certificate.Subject; Thumbprint=$Certificate.Thumbprint; ZipPath=$ZipPath; Sha256=$Hash }
}
finally {
    $Certificate.Dispose()
    [Array]::Clear($CertificateBytes,0,$CertificateBytes.Length)
}
