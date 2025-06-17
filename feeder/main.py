import time
import json
import requests
import os
import socket
import sys
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Configuration
API_KEY = os.getenv("API_KEY", "")
API_URL = "https://adsb.dataero.eu:4443/messages"
READSB_DATA = os.getenv("READSB_DATA", "/run/readsb/aircraft.json")
DEBUG = os.getenv("DEBUG", "FALSE").upper() == "TRUE"
DEBUG_LOG = "/var/log/dataero-adsb-feeder.log" if DEBUG else None

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
    "X-Target-Host": "adsb.dataero.eu"
}

def log_debug(message):
    """Append a message to the debug log with a timestamp if DEBUG is TRUE."""
    if DEBUG:
        with open(DEBUG_LOG, "a") as log_file:
            timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
            log_file.write(f"[{timestamp}] {message}\n")

def send_data():
    """Read JSON data and send it to the API, logging the process."""
    if not os.path.exists(READSB_DATA):
        log_debug(f"Error: File not found: {READSB_DATA}")
        sys.exit(1)
    try:
        with open(READSB_DATA, "r") as f:
            data = json.load(f)

        # Send the data
        response = requests.post(API_URL, headers=HEADERS, json=data)
        log_debug(f"Response: {response.status_code} {response.text}")

    except Exception as e:
        log_debug(f"Error: {e}")

if __name__ == "__main__":
    while True:
        send_data()
        time.sleep(2)
