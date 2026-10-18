# LampBar

A tiny macOS menu bar app to control a **Mi Smart LED Desk Lamp 1S** (`yeelink.light.lamp4`) over the local network. No cloud is involved at runtime.

- Turn it on or off
- Brightness (1–100%)
- Color temperature (2600–5000K)
- Presets: **Reading**, **PC Mode**, **Custom** (all editable in Settings; "Save current as Custom" in the panel)

## Build & run

```bash
./build-app.sh            # builds build/LampBar.app
./build-app.sh --install  # also copies it to /Applications
open build/LampBar.app
```

Requires macOS 14+ and Xcode / Swift 5.10+. On first use, macOS asks for **Local Network** access. Allow it, or the app can't reach the lamp.

## Getting the lamp token

The lamp uses Xiaomi's encrypted miIO protocol (UDP 54321), so the app needs the device's 32-character **token**. Current firmware hides the token on the LAN, but your Mi Home account can provide it:

1. Download [Xiaomi Cloud Tokens Extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) and run it.
2. Sign in with your Mi Home account and pick your server region (the one set in Mi Home).
3. Find the entry for the desk lamp (IP `10.0.0.4`, model `yeelink.light.lamp4`) and copy its `TOKEN`.
4. In LampBar, open **Settings…**, paste the token, then click **Save & Connect**.

The token is stored in your login Keychain. It changes if the lamp is reset or re-paired in Mi Home.

**Tip:** give the lamp a DHCP reservation on your router so its IP stays at `10.0.0.4`.

## Automation (Settings → Automation)

- **Turn lamp off when Mac sleeps:** sleep includes closing the lid and the Apple menu → Sleep. macOS holds off sleeping for up to 8s while the lamp switches off.
- **Turn lamp on when I log in or unlock:** triggers on unlocking the screen, waking without a password prompt, switching back to your user account, and LampBar starting at login. It retries for about 15s while Wi-Fi reconnects.
- **Open LampBar at login:** keep this on so the automations work after a restart. It works best with the app in `/Applications` (`./build-app.sh --install`).

## Notes

- `build-app.sh` signs with your Apple Development certificate when one is available, so the Keychain "Always Allow" survives rebuilds. With ad-hoc signing, macOS asks for Keychain access again after every rebuild.

- The 1S is a white-only (tunable white) lamp with no RGB LEDs, so "Custom" is a custom color temperature plus brightness.
- The app tries Yeelight-style miIO commands first (`get_prop`, `set_ct_abx`, …). If the firmware doesn't support them, it falls back to MIoT `get_properties` / `set_properties`.
- The lamp's state is refreshed when the panel opens and every 30s, so changes made from Mi Home show up.
