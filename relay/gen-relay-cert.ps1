<#
.SYNOPSIS
    Creates the LiwaLink tunnel CA and the relay's TLS certificate (Windows
    counterpart of gen-relay-cert.sh).

.DESCRIPTION
    Writes ca.key, ca.crt, relay.key and relay.crt (PEM) to OutDir. Existing
    files are kept, so installed agents keep trusting the relay. ca.crt is
    public; the keys never leave the relay.

    Needs no OpenSSL: runs on Windows PowerShell 5.1 (.NET Framework 4.7.2 or
    later) and on PowerShell 7.

.EXAMPLE
    .\gen-relay-cert.ps1 -Domain link.example.com -OutDir C:\ProgramData\LiwaLink\tls
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')]
    [string] $Domain,

    [Parameter(Mandatory, Position = 1)]
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'
$X509 = 'System.Security.Cryptography.X509Certificates'

# --- PEM/DER helpers (.NET Framework cannot export PEM keys itself) ------------

function New-DerElement([byte] $Tag, [byte[]] $Content) {
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add($Tag)
    $length = $Content.Length
    if ($length -lt 0x80) {
        $out.Add([byte] $length)
    } else {
        $lengthBytes = New-Object System.Collections.Generic.List[byte]
        while ($length -gt 0) { $lengthBytes.Insert(0, [byte] ($length -band 0xFF)); $length = $length -shr 8 }
        $out.Add([byte] (0x80 -bor $lengthBytes.Count))
        $out.AddRange($lengthBytes)
    }
    $out.AddRange($Content)
    return , $out.ToArray()
}

function New-DerInteger([byte[]] $Unsigned) {
    # RSA parameters are unsigned big-endian; DER integers are signed.
    $start = 0
    while ($start -lt $Unsigned.Length - 1 -and $Unsigned[$start] -eq 0) { $start++ }
    $value = New-Object System.Collections.Generic.List[byte]
    if ($Unsigned[$start] -band 0x80) { $value.Add(0) }
    for ($i = $start; $i -lt $Unsigned.Length; $i++) { $value.Add($Unsigned[$i]) }
    return , (New-DerElement 0x02 $value.ToArray())
}

function ConvertTo-Pem([string] $Label, [byte[]] $Der) {
    $base64 = [Convert]::ToBase64String($Der)
    $lines = for ($i = 0; $i -lt $base64.Length; $i += 64) {
        $base64.Substring($i, [Math]::Min(64, $base64.Length - $i))
    }
    "-----BEGIN $Label-----`n" + ($lines -join "`n") + "`n-----END $Label-----`n"
}

function ConvertTo-RsaKeyPem([System.Security.Cryptography.RSA] $Rsa) {
    # PKCS#1 RSAPrivateKey: version, n, e, d, p, q, d mod (p-1), d mod (q-1), q^-1 mod p
    $p = $Rsa.ExportParameters($true)
    $body = New-Object System.Collections.Generic.List[byte]
    foreach ($part in @([byte[]] @(0), $p.Modulus, $p.Exponent, $p.D, $p.P, $p.Q, $p.DP, $p.DQ, $p.InverseQ)) {
        $body.AddRange([byte[]] (New-DerInteger $part))
    }
    ConvertTo-Pem 'RSA PRIVATE KEY' (New-DerElement 0x30 $body.ToArray())
}

# --- certificates ----------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$paths = @{}
foreach ($name in 'ca.key', 'ca.crt', 'relay.key', 'relay.crt') { $paths[$name] = Join-Path $OutDir $name }
$existing = @($paths.Values | Where-Object { Test-Path $_ })
if ($existing.Count -eq 4) {
    $current = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $paths['relay.crt']).GetNameInfo('DnsName', $false)
    if ($current -ne $Domain) {
        throw "$($paths['relay.crt']) is for $current, not $Domain. To change the relay's domain, delete $OutDir and run again; installed agents will then need reinstalling."
    }
    Write-Host "Keeping existing certificates in $OutDir"
    return
}
if ($existing.Count -gt 0) {
    throw "$OutDir has only some of the certificate files. Delete the folder to start over; installed agents will then need reinstalling."
}

$sha256 = [System.Security.Cryptography.HashAlgorithmName]::SHA256
$pkcs1 = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
$notBefore = [DateTimeOffset]::UtcNow.AddDays(-1)
$notAfter = $notBefore.AddYears(10)

$caKey = [System.Security.Cryptography.RSA]::Create(3072)
$caRequest = New-Object "$X509.CertificateRequest" ('CN=LiwaLink Relay CA', $caKey, $sha256, $pkcs1)
$caRequest.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" ($true, $true, 0, $true)))
$caRequest.CertificateExtensions.Add((New-Object "$X509.X509KeyUsageExtension" (
    [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags] 'KeyCertSign, CrlSign', $true)))
$caRequest.CertificateExtensions.Add((New-Object "$X509.X509SubjectKeyIdentifierExtension" ($caRequest.PublicKey, $false)))
$ca = $caRequest.CreateSelfSigned($notBefore, $notAfter)

$relayKey = [System.Security.Cryptography.RSA]::Create(2048)
$relayRequest = New-Object "$X509.CertificateRequest" ("CN=$Domain", $relayKey, $sha256, $pkcs1)
$relayRequest.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" ($false, $false, 0, $false)))
$relayRequest.CertificateExtensions.Add((New-Object "$X509.X509KeyUsageExtension" (
    [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags] 'DigitalSignature, KeyEncipherment', $true)))
$serverAuth = New-Object System.Security.Cryptography.OidCollection
$serverAuth.Add((New-Object System.Security.Cryptography.Oid '1.3.6.1.5.5.7.3.1')) | Out-Null
$relayRequest.CertificateExtensions.Add((New-Object "$X509.X509EnhancedKeyUsageExtension" ($serverAuth, $false)))
$san = New-Object "$X509.SubjectAlternativeNameBuilder"
$san.AddDnsName($Domain)
$relayRequest.CertificateExtensions.Add($san.Build())
$serial = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($serial)
$serial[0] = $serial[0] -band 0x7F  # keep the serial number positive
$relay = $relayRequest.Create($ca, $notBefore, $notAfter.AddDays(-1), $serial)

[IO.File]::WriteAllText($paths['ca.key'], (ConvertTo-RsaKeyPem $caKey))
[IO.File]::WriteAllText($paths['ca.crt'], (ConvertTo-Pem 'CERTIFICATE' $ca.RawData))
[IO.File]::WriteAllText($paths['relay.key'], (ConvertTo-RsaKeyPem $relayKey))
[IO.File]::WriteAllText($paths['relay.crt'], (ConvertTo-Pem 'CERTIFICATE' $relay.RawData))
Write-Host "Created CA ($($paths['ca.crt'])) and relay certificate for $Domain"
