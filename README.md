# Dataero ADS-B Feeder

Our feeder is a Python application that reads ADS-B data from a local JSON file and sends it to the Dataero ADS-B service.

Dataero's ADS-B feeder can be configured on top of other feeds already configured on your system. It is designed to be simple and lightweight, requiring minimal system resources.

You can access our live tracking page at: 
https://adsb.dataero.eu


## Requirements

- A Raspberry Pi with ADSB reception capability
- An API key that can be obtained at: https://adsb.dataero.eu/get_api_key

## Install readsb (if not already done)

Visit the following page for automatic installation instructions for readsb:
https://github.com/wiedehopf/adsb-scripts/wiki/Automatic-installation-for-readsb


## Installation

1. On your Raspberry Pi, clone this repository:
   ```
   git clone https://github.com/dataero-adsb/dataero-adsb-feeder.git
   cd dataero-adsb-feeder
   ```

2. Run the installer script:
   ```
   sudo bash installer.sh
   ```

3. When prompted, enter your Dataero API key. If you don't have a Dataero API key yet, you can get one at: https://adsb.dataero.eu/get_api_key

The installer will:
- Check for Python 3 and readsb service
- Create an installation directory at /usr/local/dataero-adsb-feeder
- Set up a Python virtual environment and install dependencies
- Create a .env file with your API key
- Set up and start a systemd service to run the feeder automatically

## Usage

After running the installer, the feeder runs as a systemd service and starts automatically on boot. You can manage it with standard systemd commands:

```
sudo systemctl status dataero-feeder.service  # Check status
sudo systemctl restart dataero-feeder.service # Restart the service
sudo systemctl stop dataero-feeder.service    # Stop the service
```

The service will continuously read ADS-B data from the JSON file specified in the READSB_DATA environment variable and send it to the Dataero service.

## Configuration

The configuration file is located at `/usr/local/dataero-adsb-feeder/.env`. To modify configuration after installation:

```
sudo nano /usr/local/dataero-adsb-feeder/.env
```

After changing configuration, restart the service:

```
sudo systemctl restart dataero-feeder.service
```

### Available Configuration Options

- `API_KEY`: Your Dataero API key (required). If you don't have one yet, you can get one at: https://adsb.dataero.eu/get_api_key
- `DEBUG`: Set to `TRUE` to enable debug logging, or `FALSE` to disable it (default: `FALSE`)
- `READSB_DATA`: The path to the local JSON file containing ADS-B data (default: `/run/readsb/aircraft.json`)

Additional configuration options can be found in the `feeder/main.py` file:

- `API_URL`: The URL of the Dataero ADS-B service

## Troubleshooting

Check the systemd service logs:

```
sudo journalctl -u dataero-feeder.service
```

If debugging is enabled (`DEBUG=TRUE` in the .env file), check `/var/log/dataero-adsb-feeder.log` for detailed logs.

## License

This project is licensed under the terms of the license included in the repository.
