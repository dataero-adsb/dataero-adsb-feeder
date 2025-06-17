#!/bin/bash

INSTALL_DIR="/usr/local/dataero-adsb-feeder"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/dataero-feeder.service"

echo "🚀 Starting Dataero ADS-B Feeder Installer..."

# Check for Python 3
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is not installed. Please install it and rerun this script."
    exit 1
else
    echo "✅ Python 3 is installed."
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
