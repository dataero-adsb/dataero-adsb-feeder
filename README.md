# Dataero ADS-B Feeder

A Python application that reads ADS-B data from a local JSON file and sends it to the Dataero ADS-B service.

## Requirements

- Python 3.6 or higher
- readsb service installed and running
- Linux system with systemd

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/dataero-adsb-feeder.git
   cd dataero-adsb-feeder
   ```

2. Run the installer script:
   ```
   sudo bash installer.sh
   ```

3. When prompted, enter your Dataero API key.

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

- `API_KEY`: Your Dataero API key (required)
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
