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

---

## How It Works

The feeder reads aircraft data produced by `readsb` (or any compatible decoder) from a local JSON file on your system, then forwards it to the Dataero tracking platform over the internet. It runs as a background `systemd` service and starts automatically on boot.

```
[SDR Dongle] → [readsb decoder] → [aircraft.json] → [Dataero Feeder] → [radar.dataero.eu]
```

---

## Prerequisites

Before installing, make sure you have the following:
At
- A **Raspberry Pi** (or compatible Linux system) with an ADS-B receiver set up
- **`readsb`** (or a compatible ADS-B decoder) installed and running, producing `/run/readsb/aircraft.json`
- **Python 3** installed on your system
- An active internet connection
- A **Dataero account** and **API key** (see steps below)

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

- Verifies that Python 3 and the `readsb` service are available on your system
- Creates the installation directory at `/usr/local/dataero-adsb-feeder`
- Sets up a Python virtual environment and installs all required dependencies
- Writes a `.env` configuration file with your credentials
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
| `READSB_DATA` | Path to the ADS-B JSON data file produced by your decoder | `/run/readsb/aircraft.json` |
| `API_URL` | Dataero service endpoint | _(set automatically)_ |
| `DEBUG` | Enable verbose logging for troubleshooting | `FALSE` |

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
| No data appearing on radar | Feeder stopped or misconfigured | Check logs with `journalctl` and verify the service is running |

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

*Built with ❤️ by the [Dataero](https://radar.dataero.eu) community — on the broad and capable shoulders of [readsb](https://github.com/wiedehopf/readsb).*
