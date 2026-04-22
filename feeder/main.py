import time
import json
import requests
import os
import socket
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Configuration
API_KEY = os.getenv("API_KEY", "")
API_URL = "https://radar.dataero.eu/api/v1/messages"
HEARTBEAT_URL = "https://radar.dataero.eu/api/v1/heartbeat"
READSB_DATA = os.getenv("READSB_DATA", "/run/readsb/aircraft.json")
DEBUG = os.getenv("DEBUG", "FALSE").upper() == "TRUE"
DEBUG_LOG = "/var/log/dataero-adsb-feeder.log" if DEBUG else None

POLL_INTERVAL_SECONDS = 2
HEARTBEAT_INTERVAL_SECONDS = 60
REQUEST_TIMEOUT_SECONDS = 10

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
    "X-Target-Host": "radar.dataero.eu"
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
        # Don't exit — staying alive is what lets the heartbeat keep firing
        # so the API can distinguish "Pi online, readsb warming up / no
        # aircraft in range" from "Pi offline".
        log_debug(f"Skipping messages POST: file not found: {READSB_DATA}")
        return
    try:
        with open(READSB_DATA, "r") as f:
            data = json.load(f)

        response = requests.post(API_URL, headers=HEADERS, json=data, timeout=REQUEST_TIMEOUT_SECONDS)
        log_debug(f"Messages response: {response.status_code} {response.text}")

    except Exception as e:
        log_debug(f"Messages error: {e}")

def send_heartbeat():
    """POST a heartbeat so the API knows this feeder is online even when
    readsb has no aircraft to report. The feeder is identified by the bearer
    token in the header; the API records the public source IP from the TCP
    connection itself, which is more reliable than anything the Pi could
    self-report from behind NAT."""
    try:
        response = requests.post(
            HEARTBEAT_URL,
            headers=HEADERS,
            json={"timestamp": int(time.time())},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        log_debug(f"Heartbeat response: {response.status_code} {response.text}")
    except Exception as e:
        log_debug(f"Heartbeat error: {e}")

if __name__ == "__main__":
    last_heartbeat = 0.0
    while True:
        send_data()
        now = time.time()
        if now - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS:
            send_heartbeat()
            last_heartbeat = now
        time.sleep(POLL_INTERVAL_SECONDS)