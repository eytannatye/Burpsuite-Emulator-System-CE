# Install Burp CA as an Android system certificate

The scripts install the Burp CA certificate into the Android system CA store
for the current boot. Run the script again after rebooting the Android device
or emulator.

## Requirements

- A rooted Android device or emulator with USB debugging enabled.
- Exactly one connected and authorized ADB device.
- Burp Suite running on the same computer as the script.
- An active Burp proxy listener. The script asks for its port.
- Android SDK Platform Tools (`adb`) available in `PATH`.
- OpenSSL available in `PATH`.

## macOS, Linux, Git Bash, or WSL

Run:

```bash
./install_burp_ca_system.sh
```

On Windows, Git Bash is usually simpler than WSL because it can use
`adb.exe` directly. WSL requires its own working ADB setup.

## Windows PowerShell

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install_burp_ca_system.ps1
```

If `adb` or `openssl` is missing, install it and add its executable directory
to `PATH`, then open a new PowerShell window.

## Non-interactive usage

To skip the port prompt, set `BURP_PROXY_PORT`. For example:

```bash
BURP_PROXY_PORT=8082 ./install_burp_ca_system.sh
```

```powershell
$env:BURP_PROXY_PORT = "8082"
.\install_burp_ca_system.ps1
```

To use a custom certificate URL, set `BURP_CERT_URL` instead.
