# Dataero ADS-B Feeder

A Python application that reads ADS-B data from a local JSON file and sends it to the Dataero ADS-B service.

## Requirements

- Python 3.6 or higher
- pip (Python package installer)

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/dataero-adsb-feeder.git
   cd dataero-adsb-feeder
   ```

2. Install the required dependencies:
   ```
   pip install -r requirements.txt
   ```

3. Set up your environment variables:
   - Copy the `.env.example` file to a new file named `.env`:
     ```
     cp .env.example .env
     ```
   - Edit the `.env` file and replace `your_api_key_here` with your actual Dataero API key

## Usage

Run the feeder script:
```
python -m feeder.main
```

The script will continuously read ADS-B data from the JSON file specified in the READSB_DATA environment variable and send it to the Dataero service.

## Configuration

The following configuration options are available in the `.env` file:

- `API_KEY`: Your Dataero API key (required)
- `DEBUG`: Set to `TRUE` to enable debug logging, or `FALSE` to disable it (default: `FALSE`)
- `READSB_DATA`: The path to the local JSON file containing ADS-B data (default: `/run/readsb/aircraft.json`)

Additional configuration options can be found in the `feeder/main.py` file:

- `API_URL`: The URL of the Dataero ADS-B service

## Troubleshooting

If you encounter any issues and debugging is enabled (`DEBUG=TRUE`), check the `/var/log/dataero-adsb-feeder.log` file for error messages. If debugging is disabled (`DEBUG=FALSE`), check the `debug.log` file in the application directory.

## License

This project is licensed under the terms of the license included in the repository.
