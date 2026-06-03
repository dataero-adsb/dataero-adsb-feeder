# Dataero ADS-B Feeder

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

The **Dataero ADS-B Feeder** is a lightweight Python application that reads ADS-B aviation data from your local receiver and transmits it to the [Dataero flight tracking network](https://radar.dataero.eu). By running this feeder, you contribute real-time aircraft data to a growing community of aviation enthusiasts and help improve coverage across the network.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Step 1 — Create Your Dataero Account](#step-1--create-your-dataero-account)
- [Step 2 — Get Your API Key](#step-2--get-your-api-key)
- [Step 3 — Install the Feeder](#step-3--install-the-feeder)
- [Configuration](#configuration)
- [Managing the Service](#managing-the-service)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Third-Party Software](#third-party-software)
- [License](#license)

---

## How It Works

The feeder forwards the aircraft data produced by `readsb` to the Dataero tracking platform over the internet. It runs as a background `systemd` service and starts automatically on boot.

**Beast + WireGuard.** At install the feeder registers with Dataero using your API key, receives the WireGuard config of the ingest hub it's assigned to, and brings up an encrypted tunnel. `readsb` then forwards a reduced Beast stream (carrying its UUID) to that hub over the tunnel. The feeder process itself only sends a periodic heartbeat.

```
[SDR] → [readsb] → reduced Beast (UUID) ──WireGuard tunnel──→ [Dataero ingest hub]
                                          (registered via API key → your account)
```

**How your feed is linked to your account.** Beast frames carry no credential, so identity is established **once** at registration (your API key → your account) and then re-proven on every message by the WireGuard tunnel address *and* the in-band receiver UUID. Your API key is used the same way it always was — you just paste it once at install.

---

## Prerequisites

Before installing, make sure you have the following:

- A **Raspberry Pi** (or compatible Debian-based Linux system) with an ADS-B receiver set up
- **`readsb`** installed and running (`/run/readsb/aircraft.json`) — required for the **Beast + WireGuard** feed
- **Python 3.7+** installed on your system
- An active internet connection
- A **Dataero account** and **API key** (see steps below)

> The installer auto-installs `wireguard-tools` for the Beast + WireGuard tunnel — you don't need it beforehand.

---

## Step 1 — Create Your Dataero Account

You need a free Dataero account to authenticate your feeder and associate it with your station on the network.

1. Open your browser and go to **[https://radar.dataero.eu](https://radar.dataero.eu)**
2. Click **Register** and fill in the registration form with your details
3. Confirm your email address if prompted
4. Log in to your new account

> **Already have an account?** Skip to [Step 2](#step-2--get-your-api-key).

---

## Step 2 — Get Your API Key

Your API key is a unique token that identifies your feeder on the Dataero network. It is required during installation.

1. Log in at **[https://radar.dataero.eu](https://radar.dataero.eu)**
2. Click on your username or avatar in the top-right corner to open the menu
3. Go to your **Profile page**
4. Locate the **API Key** section and click **Request API Key** (or copy your existing key if one has already been generated)
5. Copy the key — you will need it in the next step

> **Keep your API key private.** Do not share it publicly or commit it to version control.

---

## Step 3 — Install the Feeder

### Clone the repository

On your Raspberry Pi (or Linux system), open a terminal and run:

```bash
git clone https://github.com/dataero-adsb/dataero-adsb-feeder.git
cd dataero-adsb-feeder
```

### Run the installer

```bash
sudo bash installer.sh
```

The installer will guide you through the setup interactively. When prompted, **paste the API key** you copied from your Dataero profile page.

### What the installer does

The installer automatically:

- Checks for Python 3.7+ and confirms `readsb` is present
- Creates the installation directory at `/usr/local/dataero-adsb-feeder`
- Sets up a Python virtual environment and installs all required dependencies
- Installs `wireguard-tools`, registers this feeder with Dataero (binding it to your account via your API key), brings up the WireGuard tunnel to your assigned hub, and points `readsb` at that hub over the tunnel
- Writes a `.env` configuration file with your credentials and the assigned hub config
- Registers and starts a `systemd` service so the feeder runs automatically on boot

Once the installer completes, your feeder is live and contributing data to [radar.dataero.eu](https://radar.dataero.eu).

---

## Configuration

The feeder's configuration is stored in:

```
/usr/local/dataero-adsb-feeder/.env
```

| Setting | Description | Default |
|---|---|---|
| `API_KEY` | Your Dataero API key (required) | _(set during install)_ |
| `FEED_MODE` | Feed mode — `beast` (Beast over WireGuard) | `beast` |
| `READSB_DATA` | Path to the `aircraft.json` produced by `readsb` (used for detection) | `/run/readsb/aircraft.json` |
| `DEBUG` | Enable verbose logging for troubleshooting | `FALSE` |

**Beast-mode settings** (set automatically at install from the registration response — don't edit by hand):

| Setting | Description |
|---|---|
| `REGISTRAR_URL` | Dataero registrar base URL (`https://adsb.dataero.eu`) |
| `RECEIVER_UUID` | This feeder's receiver id — bound to your account at registration, used as `readsb --uuid` |
| `WG_PRIVKEY` / `WG_PUBKEY` | This feeder's WireGuard keypair (the public key is the registered peer identity) |
| `FEEDER_NAME` / `FEEDER_LAT` / `FEEDER_LON` / `FEEDER_ALT_M` | Optional station details (useful for MLAT later) |
| `REDUCE_INTERVAL` | readsb position-throttle interval in seconds for the reduced Beast stream (default `0.25`) |
| `SHARD` / `TUNNEL_IP` / `BEAST_HOST` / `BEAST_PORT` | The assigned ingest hub + tunnel address |

To edit the configuration after installation:

```bash
sudo nano /usr/local/dataero-adsb-feeder/.env
```

After making changes, restart the service for them to take effect:

```bash
sudo systemctl restart dataero-feeder.service
```

---

## Managing the Service

The feeder runs as a `systemd` service. Use the following commands to manage it:

| Action | Command |
|---|---|
| Check status | `sudo systemctl status dataero-feeder.service` |
| Restart | `sudo systemctl restart dataero-feeder.service` |
| Stop | `sudo systemctl stop dataero-feeder.service` |
| Start | `sudo systemctl start dataero-feeder.service` |
| Enable on boot | `sudo systemctl enable dataero-feeder.service` |
| Disable on boot | `sudo systemctl disable dataero-feeder.service` |

---

## Troubleshooting

**View live logs**

```bash
sudo journalctl -u dataero-feeder.service -f
```

**View recent logs**

```bash
sudo journalctl -u dataero-feeder.service --since "1 hour ago"
```

**Common issues**

| Problem | Likely cause | Solution |
|---|---|---|
| Service fails to start | `readsb` not running | Run `sudo systemctl start readsb` and retry |
| `aircraft.json` not found | Wrong path in config | Update `READSB_DATA` in the `.env` file |
| Authentication error | Invalid or missing API key | Check your API key on your [Dataero profile](https://radar.dataero.eu/profile) and update `API_KEY` in `.env` |
| No data appearing on radar | WireGuard tunnel down | `sudo wg show wg-adsb` — a recent handshake means the tunnel is up. If not, `sudo wg-quick down wg-adsb && sudo wg-quick up wg-adsb`, or re-run the installer to re-register |
| `registrar heartbeat: receiver unknown or disabled` in logs | Receiver removed/disabled server-side | Re-run `sudo bash installer.sh` to re-register |

Enable `DEBUG=TRUE` in the `.env` file for more detailed log output when diagnosing issues.

---

## Contributing

We welcome contributions from the community! If you find a bug, have a feature request, or want to improve the documentation, please open an issue or submit a pull request on [GitHub](https://github.com/dataero-adsb/dataero-adsb-feeder).

---

## Credits & Acknowledgements — A Love Letter to readsb ✈️

Let's be honest with ourselves for a moment.

This feeder is the *easy* half of a genuinely hard problem. The grown-up part — listening to faint 1090 MHz whispers from aircraft 200 nautical miles away, untangling thousands of overlapping Mode-S transponder bursts every second, and turning all of that radio-wizardry into clean, well-formed JSON on a $35 Raspberry Pi — is **none of our doing**. That is the work of the magnificent [**readsb**](https://github.com/wiedehopf/readsb) project, lovingly maintained by [**wiedehopf**](https://github.com/wiedehopf) and a community of contributors who clearly understand RF engineering far better than is healthy for any one human.

If this software were a band, readsb would be the lead vocalist, the lead guitarist, the drummer, the bassist, the producer, the sound engineer, and the person who wrote every single song.

We're the one handing out flyers at the door.

Without readsb, this repository would be a forty-line Python script staring forlornly at a non-existent file, slowly realising it has no purpose in life. With readsb, it gets to do something useful: passing the bytes along to [radar.dataero.eu](https://radar.dataero.eu) so the rest of the world can see where the planes are.

So — to wiedehopf, to the original [Mictronics readsb](https://github.com/Mictronics/readsb) authors it descends from, to dump1090 before that, and to every contributor who has ever filed a PR, fixed a buffer overflow, or argued about CPR decoding at 2 a.m.: **thank you.** Massively. Sincerely. Slightly awestruck.

We just relay the bytes. You make them exist.

---

## Third-Party Software

This feeder itself is released under the [MIT License](LICENSE). It depends on, and interoperates with, the following third-party software, each of which is governed by its own license:

| Component | Role | License |
|---|---|---|
| [readsb](https://github.com/wiedehopf/readsb) (wiedehopf fork) | ADS-B decoder that produces `aircraft.json` | GNU GPL — see upstream repository |
| [Mictronics readsb](https://github.com/Mictronics/readsb) | Original readsb that wiedehopf's fork descends from | GNU GPL — see upstream repository |
| [requests](https://github.com/psf/requests) | HTTP client used by the feeder | Apache License 2.0 |
| [python-dotenv](https://github.com/theskumar/python-dotenv) | `.env` file loader | BSD 3-Clause |
| [wireguard-tools](https://www.wireguard.com/) | Userspace tooling for the encrypted Beast tunnel | GNU GPL v2 |

The feeder does **not** redistribute or bundle readsb or `wireguard-tools`; the optional `feeder/install_readsb.sh` is a thin wrapper that fetches and runs the upstream installer maintained by wiedehopf at install time, and `wireguard-tools` is installed from your distribution's repositories (`apt-get`) at install time. All third-party copyrights and licenses remain with their respective authors.

---

## License

This project is licensed under the [MIT License](LICENSE). See the `LICENSE` file in the repository root for the full text.

---

*Built with ❤️ by the [Dataero](https://radar.dataero.eu) community — on the broad and capable shoulders of [readsb](https://github.com/wiedehopf/readsb).*
