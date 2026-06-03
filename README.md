# Dataero ADS-B Feeder

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Feed your ADS-B receiver's data to the [Dataero flight tracking network](https://radar.dataero.eu). It runs as a background service and starts on boot.

## What you need

- A Raspberry Pi (or any Debian/Ubuntu Linux) with **`readsb`** installed and running.
- An internet connection.

That's it — no account needed to start feeding. The installer handles everything else (WireGuard, dependencies, the service).

## Install in 2 steps

### 1. Run the installer
```bash
git clone https://github.com/dataero-adsb/dataero-adsb-feeder.git
cd dataero-adsb-feeder
sudo bash installer.sh
```

### 2. Answer the prompts
- **API key** — press **Enter to skip** (you can link the receiver to an account later, see below). If you already have one ([radar.dataero.eu](https://radar.dataero.eu) → **Profile** → **Request API Key**), paste it to link immediately.
- **MLAT?** (optional — see below) Answer `y` or `N`.

When it finishes, your feeder is live. ✈️

## Claim your receiver (if you skipped the API key)

Your receiver feeds either way — claiming it just links it to your Dataero account so you can see your stats and manage it. The installer prints a **claim link** at the end (also saved as `CLAIM_URL` in `/usr/local/dataero-adsb-feeder/.env`): open it in a browser while signed in at [radar.dataero.eu](https://radar.dataero.eu). Or simply re-run the installer with an API key.

## Optional: enable MLAT

MLAT (multilateration) lets Dataero locate older aircraft that **don't** broadcast GPS, by combining your receiver with others nearby. To take part, answer **`y`** at the MLAT prompt and enter your antenna's **exact** position:

- **Latitude, Longitude, Altitude (metres)** — be precise. Even a few metres of error degrades every MLAT result.

The installer then sets up a second service, `dataero-mlat.service`, automatically. You can change your mind later by re-running `sudo bash installer.sh`. MLAT only produces results once several nearby receivers are taking part — so don't worry if you don't see it working immediately.

## Manage the feeder

```bash
sudo systemctl status  dataero-feeder.service     # is it running?
sudo systemctl restart dataero-feeder.service     # restart
sudo journalctl -u dataero-feeder.service -f      # live logs
```
If you enabled MLAT, swap `dataero-feeder` for `dataero-mlat` to manage that service.

**To update:** `git pull` in the repo folder, then `sudo bash installer.sh` again (it reuses your existing settings).

## Uninstall

```bash
sudo bash uninstaller.sh
```
Surgical: removes only Dataero's services (`dataero-feeder`/`dataero-readsb`/`dataero-mlat`), the `wg-adsb` tunnel, and `/usr/local/dataero-adsb-feeder`. It never touches the shared decoder, other feeders, other WireGuard interfaces, or apt packages.

## Troubleshooting

| Problem | Fix |
|---|---|
| Service won't start | Make sure `readsb` runs: `sudo systemctl start readsb`, then re-run the installer. |
| Authentication error | Re-check your API key on your [profile](https://radar.dataero.eu/profile) and re-run the installer. |
| No data on radar | Check the tunnel: `sudo wg show wg-adsb` (a recent handshake = OK). If not, re-run the installer. |
| MLAT not working | Needs ≥3 nearby receivers + an accurate position. Check `sudo journalctl -u dataero-mlat.service`. |

Config lives in `/usr/local/dataero-adsb-feeder/.env`. Set `DEBUG=TRUE` there (then restart the service) for verbose logs.

## Credits

The hard part — turning faint 1090 MHz radio into clean data — is done by [**readsb**](https://github.com/wiedehopf/readsb) (wiedehopf). We just relay the bytes. Thank you. 🙏

## Third-party software & licenses

This feeder is [MIT](LICENSE) licensed. It interoperates with (but does not bundle) third-party software under its own license:

| Component | Role | License |
|---|---|---|
| [readsb](https://github.com/wiedehopf/readsb) (wiedehopf) | ADS-B decoder (`aircraft.json`) | GNU GPL |
| [mlat-client](https://github.com/wiedehopf/mlat-client) (wiedehopf) | MLAT client (optional) | GNU GPL v3 |
| [requests](https://github.com/psf/requests) | HTTP client | Apache 2.0 |
| [python-dotenv](https://github.com/theskumar/python-dotenv) | `.env` loader | BSD 3-Clause |
| [wireguard-tools](https://www.wireguard.com/) | Encrypted tunnel | GNU GPL v2 |

`readsb`, `mlat-client`, and `wireguard-tools` are fetched/installed from upstream at install time; all copyrights remain with their authors.

---

*Built with ❤️ by the [Dataero](https://radar.dataero.eu) community, on the shoulders of [readsb](https://github.com/wiedehopf/readsb).*
