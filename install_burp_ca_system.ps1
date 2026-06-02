$ErrorActionPreference = "Stop"

$Adb = if ($env:ADB) { $env:ADB } else { "adb" }
$WorkDir = if ($env:WORKDIR) { $env:WORKDIR } else { Join-Path $env:TEMP "burp-system-ca" }

function Require-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Run-Adb {
    & $Adb @args
    if ($LASTEXITCODE -ne 0) {
        throw "adb command failed: adb $($args -join ' ')"
    }
}

Require-Command $Adb
Require-Command "openssl"

$Devices = @(& $Adb devices | Select-String "	device$")
if ($Devices.Count -ne 1) {
    throw "Expected exactly one connected ADB device, found: $($Devices.Count). Connect one rooted Android device or emulator and authorize USB debugging."
}

if ($env:BURP_CERT_URL) {
    $BurpCertUrl = $env:BURP_CERT_URL
} else {
    $BurpProxyPort = if ($env:BURP_PROXY_PORT) {
        $env:BURP_PROXY_PORT
    } else {
        Read-Host "[?] Enter Burp proxy port"
    }

    $ParsedPort = 0
    if (-not [int]::TryParse($BurpProxyPort, [ref]$ParsedPort) -or
        $ParsedPort -lt 1 -or
        $ParsedPort -gt 65535) {
        throw "Invalid proxy port: $BurpProxyPort"
    }

    $BurpCertUrl = "http://127.0.0.1:$ParsedPort/cert"
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Der = Join-Path $WorkDir "burp.der"
$Pem = Join-Path $WorkDir "burp.pem"

Write-Host "[*] Downloading Burp CA from $BurpCertUrl"
Invoke-WebRequest -Uri $BurpCertUrl -OutFile $Der -UseBasicParsing

Write-Host "[*] Converting certificate"
& openssl x509 -inform DER -in $Der -out $Pem
if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert the Burp certificate."
}

$Hash = (& openssl x509 -inform PEM -subject_hash_old -in $Pem | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $Hash) {
    throw "Failed to calculate the Android certificate hash."
}

$Cert = "$Hash.0"
$CertPath = Join-Path $WorkDir $Cert
Copy-Item -Force $Pem $CertPath

Write-Host "[*] Certificate hash: $Cert"
Write-Host "[*] Checking root access"
& $Adb root *> $null
Run-Adb wait-for-device

$ShellUid = (& $Adb shell id -u).Trim()
if ($ShellUid -eq "0") {
    $RootShell = @("shell", "sh")
} else {
    & $Adb shell su -c id *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Root access is required: adbd is not root and su is unavailable."
    }
    $RootShell = @("shell", "su", "-c", "sh")
}

Write-Host "[*] Pushing certificate"
Run-Adb push $CertPath "/data/local/tmp/$Cert"

$InstallScript = @'
set -e
CERT='__CERT__'
CACHE="/data/local/tmp/burp-system-cacerts-$$"
trap 'rm -rf "$CACHE"' EXIT
mkdir -p "$CACHE"
cp /system/etc/security/cacerts/* "$CACHE/"
cp "/data/local/tmp/$CERT" "$CACHE/$CERT"
chmod 644 "$CACHE"/*

for STORE in \
  /system/etc/security/cacerts \
  /apex/com.android.conscrypt/cacerts \
  /apex/com.android.conscrypt/etc/security/cacerts
do
  [ -d "$STORE" ] || continue
  mountpoint -q "$STORE" || mount -t tmpfs tmpfs "$STORE"
  cp "$CACHE"/* "$STORE/"
  chmod 644 "$STORE"/*
  chcon u:object_r:system_file:s0 "$STORE"/* 2>/dev/null || true
  ls -l "$STORE/$CERT"
done
'@.Replace("__CERT__", $Cert)

Write-Host "[*] Installing certificate into system CA store using tmpfs"
$InstallScript | & $Adb @RootShell
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install the certificate into the Android system CA store."
}

Write-Host "[+] Installed Burp CA as system CA: /system/etc/security/cacerts/$Cert"
Write-Host "[!] This is runtime-only. Re-run after emulator reboot."
