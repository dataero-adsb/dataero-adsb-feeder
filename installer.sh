#!/bin/bash
set -e

INSTALL_DIR="/usr/local/dataero-adsb-feeder"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/dataero-feeder.service"

echo "🚀 Starting Dataero ADS-B Feeder Installer..."

# Ensure apt-get is available (required to install any missing Python packages)
if ! command -v apt-get &> /dev/null; then
    echo "❌ apt-get not found. This installer supports Debian-based systems only (Raspberry Pi OS, Debian, Ubuntu)."
    echo "   Please install python3, python3-pip, and python3-venv manually, then rerun this script."
    exit 1
fi

# Phase 1: ensure python3 itself is present so we can inspect its version.
if ! command -v python3 &> /dev/null; then
    echo "⚠️  python3 not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3
    command -v python3 &> /dev/null || { echo "❌ python3 still unavailable after install."; exit 1; }
fi

# Detect the running Python version so we request the matching venv package
# (e.g. python3.11-venv on Bookworm, python3.12-venv on Trixie/Ubuntu 24.04).
# On current Debian/Ubuntu the meta-package python3-venv does NOT reliably
# pull in the versioned one, which is why `python3 -m venv` later fails with
# "ensurepip is not available" when only the meta-package is installed.
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
VENV_PKG="python${PY_VER}-venv"

# Phase 2: check pip and the versioned venv package. dpkg -s is authoritative;
# `python3 -m venv --help` gives false positives because the stub is part of
# stdlib and succeeds even when ensurepip's wheels are missing.
MISSING_PKGS=()
python3 -m pip --version &> /dev/null || MISSING_PKGS+=("python3-pip")
dpkg -s "$VENV_PKG" &> /dev/null      || MISSING_PKGS+=("$VENV_PKG")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "⚠️  Missing Python prerequisites: ${MISSING_PKGS[*]}"
    echo "📦 Installing via apt-get..."
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PKGS[@]}"
    python3 -m pip --version &> /dev/null || { echo "❌ pip still unavailable after install."; exit 1; }
    dpkg -s "$VENV_PKG" &> /dev/null      || { echo "❌ $VENV_PKG still not installed."; exit 1; }
    echo "✅ Python prerequisites installed."
else
    echo "✅ Python 3, pip, and $VENV_PKG are all available."
fi

# If a previous run left a half-built venv behind, remove it so `python3 -m venv`
# can re-bootstrap cleanly instead of tripping over stale files.
if [ -d "$VENV_DIR" ] && [ ! -x "$VENV_DIR/bin/pip" ]; then
    echo "🧹 Removing broken venv at $VENV_DIR from a previous run..."
    sudo rm -rf "$VENV_DIR"
fi

# Check for readsb service
if ! systemctl list-units --type=service --all | grep -q "readsb.service"; then
    echo "❌ readsb.service is not installed."
    read -p "Do you want to automatically install readsb? (yes/no): " install_readsb
    if [[ "$install_readsb" == "yes" ]]; then
        echo "🔄 Installing readsb..."
        bash "$(dirname "$0")/feeder/install_readsb.sh"

        # Verify installation was successful
        if systemctl list-units --type=service --all | grep -q "readsb.service"; then
            echo "✅ readsb.service is now installed."
            if ! systemctl is-active --quiet readsb.service; then
                echo "⚠️ readsb.service is not running. Attempting to start it..."
                sudo systemctl start readsb.service
                if systemctl is-active --quiet readsb.service; then
                    echo "✅ readsb.service started successfully."
                else
                    echo "❌ Failed to start readsb.service. Please start it manually."
                    exit 1
                fi
            else
                echo "✅ readsb.service is running."
            fi
        else
            echo "❌ Failed to install readsb.service. Please install it manually."
            exit 1
        fi
    else
        echo "❌ readsb.service is required for this application to function. Please install it and run this script again."
        exit 1
    fi
else
    echo "✅ readsb.service is installed."
    if ! systemctl is-active --quiet readsb.service; then
        echo "⚠️ readsb.service is not running. Attempting to start it..."
        sudo systemctl start readsb.service
        if systemctl is-active --quiet readsb.service; then
            echo "✅ readsb.service started successfully."
        else
            echo "❌ Failed to start readsb.service. Please start it manually."
            exit 1
        fi
    else
        echo "✅ readsb.service is already running."
    fi
fi

# Create installation directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo "📁 Creating installation directory at $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
    echo "✅ Directory created."
else
    echo "📁 Installation directory already exists."
fi

# Copy Python files to the install directory
echo "📦 Copying Python files to $INSTALL_DIR..."
sudo cp -r feeder "$INSTALL_DIR/"
sudo cp requirements.txt "$INSTALL_DIR/"
echo "✅ Files copied."

# Set up virtual environment
echo "🐍 Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$INSTALL_DIR/requirements.txt"
deactivate
echo "✅ Virtual environment ready."

# Prompt for API key
echo "🔑 If you don't have a Dataero API key yet, you can get one at: https://adsb.dataero.eu/get_api_key"
read -p "🔑 Enter your Dataero API key: " API_KEY
echo "API_KEY=$API_KEY" | sudo tee "$INSTALL_DIR/.env" > /dev/null
echo "✅ API key saved."

# Create systemd service file
echo "🛠️ Creating systemd service..."
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Dataero ADS-B Feeder Service
Requires=readsb.service
After=readsb.service

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/feeder/main.py
EnvironmentFile=$INSTALL_DIR/.env
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable service
echo "🔄 Reloading systemd daemon..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable dataero-feeder.service
sudo systemctl start dataero-feeder.service

echo "✅ Service installed and started successfully!"
echo "🎉 Installation complete. Your feeder is now running."
