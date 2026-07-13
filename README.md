# Dataero ADS-B Feeder

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

The **Dataero ADS-B Feeder** connects your ADS-B receiver to the [Dataero flight tracking network](https://radar.dataero.eu). It forwards a bandwidth-reduced Beast stream from your existing `readsb` decoder directly to a Dataero ingest hub — **no account, no API key, and no changes to your current setup required**. Plug it in, start feeding, and claim your receiver whenever you like.

---

## Table of Contents

* [How It Works](#how-it-works)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Claiming Your Receiver](#claiming-your-receiver)
* [MLAT (Multilateration)](#mlat-multilateration)
* [Configuration](#configuration)
* [Managing the Services](#managing-the-services)
* [Troubleshooting](#troubleshooting)
* [Contributing](#contributing)

---

## How It Works

```
[SDR Dongle] → [readsb decoder] → [Dataero Beast forwarder] ──TCP──> [Dataero ingest hub]
                     (yours,           (dedicated read-only
                    untouched)          readsb instance)
```

At install time, the feeder registers your receiver with the Dataero network and receives the address of its assigned ingest hub. A **dedicated, network-only readsb instance** (`dataero-readsb.service`) then taps your existing decoder read-only on `127.0.0.1:30005` — the same port every other feeder uses — and forwards a reduced Beast stream, tagged with your receiver's unique ID, straight to that hub.

Your receiver is identified on the wire by a UUID generated during installation. It starts feeding **immediately and anonymously**; linking it to a Dataero account is optional and can be done at any time (see [Claiming Your Receiver](#claiming-your-receiver)).

**Your existing setup is never touched.** The installer does not modify, reconfigure, or restart your shared decoder. Feeding Dataero alongside FlightAware, Flightradar24, ADSBExchange, adsb.fi, or any other network works out of the box — they are all just independent readers of the same decoder.

---

## Prerequisites

* A **Raspberry Pi** (or any Debian-based Linux system: Raspberry Pi OS, Debian, Ubuntu) with an ADS-B receiver
* **[`readsb`](https://github.com/wiedehopf/readsb)** installed and running — required, since the feed uses readsb's native `beast_reduce_plus_out` connector. **If you don't have a decoder yet, the installer offers to install readsb for you.**
* **Python 3.7+** (present on any current OS image; the installer installs missing pieces)
* An active internet connection

That's it. No account and no key are needed to start feeding.

---

## Installation

### Clone the repository

```bash
git clone https://github.com/dataero-adsb/dataero-adsb-feeder.git
cd dataero-adsb-feeder
```

### Run the installer

```bash
sudo bash installer.sh
```

The installer will interactively ask for:

* **Station name** — optional, press Enter to skip
* **MLAT opt-in** — yes/no (see [MLAT](#mlat-multilateration))
* **Antenna position** (latitude / longitude / altitude) — **mandatory and must be accurate if MLAT is enabled**; optional otherwise

### What the installer does

* Detects your decoder (and offers to install `readsb` if none is found)
* Registers your receiver with the Dataero network and generates its unique **receiver UUID**
* Sets up the dedicated Beast forwarder (`dataero-readsb.service`) pointing at your assigned ingest hub
* Installs the feeder daemon (`dataero-feeder.service`), which sends periodic heartbeats
* If MLAT was enabled: installs and starts `mlat-client` (`dataero-mlat.service`)
* Runs post-install checks and prints your **receiver UUID and claim instructions**

Re-running the installer is safe: it reuses your existing receiver UUID, station name, and position, so your receiver's identity and account link are preserved across reinstalls and upgrades.

Once the installer completes, your data is live on [radar.dataero.eu](https://radar.dataero.eu).

---

## Claiming Your Receiver

Your receiver starts feeding **unclaimed** — it works, but it isn't linked to any account yet. Claiming it gives you access to your personal feeder statistics and dashboard.

1. Go to **<https://radar.dataero.eu>** and **register** a free account (or sign in)
2. Open your **Profile page** → **Receiver** tab
3. Under **"Link a receiver"**, paste your **Dataero receiver UUID**

The UUID is printed at the end of the installation. Lost it? Read it back from the device:

```bash
sudo grep RECEIVER_UUID /usr/local/dataero-adsb-feeder/.env
```

> ⚠️ **Use the Dataero receiver UUID — not your ultrafeeder / readsb UUID.** They are different identifiers; pasting the ultrafeeder one will give "receiver not found".

You can claim your receiver at any time — today, next week, or next month. It keeps feeding either way.

---

## MLAT (Multilateration)

MLAT lets the Dataero network compute positions for Mode-S aircraft that don't broadcast their GPS position, by combining precise signal timing from your receiver and others nearby.

* Opt in during installation (or re-run the installer later to enable it)
* MLAT requires an **accurate, surveyed antenna position** — latitude, longitude, and altitude above sea level in metres. A position error of a few metres degrades every multilateration result, so use a GPS reading at the antenna or a precise map tool.
* When enabled, a separate `dataero-mlat.service` runs `mlat-client` against your local decoder — independent of the ADS-B feed.

If the server declines MLAT (e.g. missing or incomplete position), ADS-B feeding continues normally; re-run the installer with a full position to enable it.

---

## Configuration

The feeder's configuration is stored in:

```
/usr/local/dataero-adsb-feeder/.env
```

| Setting | Description | Default |
| --- | --- | --- |
| `RECEIVER_UUID` | Your receiver's unique ID — generated at install, reused on reinstall. Needed to claim the receiver. | *(generated)* |
| `FEEDER_NAME` | Optional station name | *(empty)* |
| `FEEDER_LAT` / `FEEDER_LON` / `FEEDER_ALT_M` | Antenna position (mandatory for MLAT) | *(empty)* |
| `MLAT_ENABLED` | Effective MLAT state as confirmed by the server | `false` |
| `BEAST_HOST` / `BEAST_PORT` | Assigned ingest hub endpoint — set by the installer, do not edit by hand | *(assigned)* |
| `REDUCE_INTERVAL` | readsb position-throttle interval in seconds | `0.25` |
| `READSB_DATA` | Path to your decoder's `aircraft.json` | `/run/readsb/aircraft.json` |
| `DEBUG` | Verbose logging for troubleshooting | `FALSE` |

To change your station name or position, the recommended way is simply to **re-run the installer** — it pre-fills your current values and re-registers cleanly. After manual edits, restart the services:

```bash
sudo systemctl restart dataero-feeder.service dataero-readsb.service
```

---

## Managing the Services

The feeder consists of two (or three, with MLAT) systemd services:

| Service | Role |
| --- | --- |
| `dataero-readsb.service` | Dedicated net-only readsb instance forwarding reduced Beast to your hub |
| `dataero-feeder.service` | Registration heartbeat daemon |
| `dataero-mlat.service` | mlat-client (only when MLAT is enabled) |

Common commands (replace the service name as needed):

| Action | Command |
| --- | --- |
| Check status | `sudo systemctl status dataero-readsb.service` |
| Restart | `sudo systemctl restart dataero-readsb.service` |
| Stop | `sudo systemctl stop dataero-readsb.service` |
| Live logs | `sudo journalctl -u dataero-readsb.service -f` |

---

## Troubleshooting

**View live logs**

```bash
sudo journalctl -u dataero-feeder.service -f
sudo journalctl -u dataero-readsb.service -f
```

**Common issues**

| Problem | Likely cause | Solution |
| --- | --- | --- |
| Installer aborts: decoder not readsb | The feed requires readsb's `beast_reduce_plus_out` connector | Install [readsb](https://github.com/wiedehopf/readsb) and re-run the installer |
| Services fail to start | `readsb` not running | `sudo systemctl start readsb` and retry |
| Heartbeat returns 404 | Receiver removed or disabled server-side | Re-run the installer to re-register |
| "Receiver not found" when claiming | Wrong UUID pasted (ultrafeeder/readsb UUID instead of the Dataero one) | Use `sudo grep RECEIVER_UUID /usr/local/dataero-adsb-feeder/.env` |
| No data on the map | Forwarder stopped, or no reception | Check `dataero-readsb.service` logs and your antenna |

Enable `DEBUG=TRUE` in the `.env` file for more detailed output when diagnosing issues.

---

## Contributing

We welcome contributions from the community! If you find a bug, have a feature request, or want to improve the documentation, please open an issue or submit a pull request on [GitHub](https://github.com/dataero-adsb/dataero-adsb-feeder).

---

*Built with ❤️ by the [Dataero](https://radar.dataero.eu) community. The bytes you relay are decoded by the excellent [readsb](https://github.com/wiedehopf/readsb) — if you ever meet wiedehopf or a readsb maintainer, buy them a coffee. We owe them the entire upper half of this stack.*
