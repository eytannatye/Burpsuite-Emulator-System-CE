#!/usr/bin/env bash
set -euo pipefail

ADB="${ADB:-adb}"
WORKDIR="${WORKDIR:-/tmp/burp-system-ca}"

for COMMAND in "$ADB" curl openssl; do
  if ! command -v "$COMMAND" >/dev/null 2>&1; then
    echo "[!] Missing required command: $COMMAND" >&2
    exit 1
  fi
done

DEVICE_COUNT="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')"
if [ "$DEVICE_COUNT" -ne 1 ]; then
  echo "[!] Expected exactly one connected ADB device, found: $DEVICE_COUNT" >&2
  echo "[!] Connect one rooted Android device or emulator and authorize USB debugging." >&2
  exit 1
fi

if [ -z "${BURP_CERT_URL:-}" ]; then
  if [ -z "${BURP_PROXY_PORT:-}" ]; then
    read -r -p "[?] Enter Burp proxy port: " BURP_PROXY_PORT
  fi

  if ! [[ "$BURP_PROXY_PORT" =~ ^[0-9]+$ ]] ||
    [ "$BURP_PROXY_PORT" -lt 1 ] ||
    [ "$BURP_PROXY_PORT" -gt 65535 ]; then
    echo "[!] Invalid proxy port: $BURP_PROXY_PORT" >&2
    exit 1
  fi

  BURP_CERT_URL="http://127.0.0.1:$BURP_PROXY_PORT/cert"
fi

mkdir -p "$WORKDIR"

DER="$WORKDIR/burp.der"
PEM="$WORKDIR/burp.pem"

echo "[*] Downloading Burp CA from $BURP_CERT_URL"
curl -fsSL "$BURP_CERT_URL" -o "$DER"

echo "[*] Converting certificate"
openssl x509 -inform DER -in "$DER" -out "$PEM"

HASH="$(openssl x509 -inform PEM -subject_hash_old -in "$PEM" | head -1)"
CERT="$HASH.0"
cp "$PEM" "$WORKDIR/$CERT"

echo "[*] Certificate hash: $CERT"
echo "[*] Checking root access"
"$ADB" root >/dev/null 2>&1 || true
"$ADB" wait-for-device

if [ "$("$ADB" shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; then
  ROOT_SHELL=("$ADB" shell sh)
elif "$ADB" shell su -c id >/dev/null 2>&1; then
  ROOT_SHELL=("$ADB" shell su -c sh)
else
  echo "[!] Root access is required: adbd is not root and su is unavailable." >&2
  exit 1
fi

echo "[*] Pushing certificate"
"$ADB" push "$WORKDIR/$CERT" "/data/local/tmp/$CERT" >/dev/null

echo "[*] Installing certificate into system CA store using tmpfs"
printf '%s\n' "set -e
CERT='$CERT'
CACHE=\"/data/local/tmp/burp-system-cacerts-\$\$\"
trap 'rm -rf \"\$CACHE\"' EXIT
mkdir -p \"\$CACHE\"
cp /system/etc/security/cacerts/* \"\$CACHE/\"
cp /data/local/tmp/\$CERT \"\$CACHE/\$CERT\"
chmod 644 \"\$CACHE\"/*

for STORE in \
  /system/etc/security/cacerts \
  /apex/com.android.conscrypt/cacerts \
  /apex/com.android.conscrypt/etc/security/cacerts
do
  [ -d \"\$STORE\" ] || continue
  mountpoint -q \"\$STORE\" || mount -t tmpfs tmpfs \"\$STORE\"
  cp \"\$CACHE\"/* \"\$STORE/\"
  chmod 644 \"\$STORE\"/*
  chcon u:object_r:system_file:s0 \"\$STORE\"/* 2>/dev/null || true
  ls -l \"\$STORE/\$CERT\"
done
" | "${ROOT_SHELL[@]}"

echo "[+] Installed Burp CA as system CA: /system/etc/security/cacerts/$CERT"
echo "[!] This is runtime-only. Re-run after emulator reboot."
