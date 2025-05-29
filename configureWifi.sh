#!/bin/sh

# === USER CONFIGURATION ===
SSID="YOUR_WIFI_SSID"
PASSWORD="YOUR_WIFI_PASSWORD"

# === PLATFORM DETECTION ===
OS="$(uname | tr '[:upper:]' '[:lower:]')"
if echo "$OS" | grep -q "mingw"; then
    PLATFORM="windows"
    echo "ERROR: Please use configureWifi.ps1"
else
    PLATFORM="linux"
fi

# === DETECT SERIAL PORT CONNECTED TO STM32MP1 ===
detect_serial_port() {
    # Try by-id first (more reliable)
    for dev in /dev/serial/by-id/*; do
        if [ -L "$dev" ]; then
            if udevadm info -q all -n "$dev" 2>/dev/null | grep -qi 'stm\|stmicro'; then
                realpath "$dev"
                return
            fi
        fi
    done

    # Fallback to first ttyUSB/ttyACM if above fails
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        if [ -e "$dev" ]; then
            echo "$dev"
            return
        fi
    done

    echo ""
}

# === SERIAL SEND FUNCTION ===
send_command() {
    CMD="$1"
    echo ">>> $CMD"
    printf "%s\r\n" "$CMD" > "$PORT"
    sleep "${2:-0.5}"
}

send_and_print_output() {
    CMD="$1"
    printf "%s\r\n" "$CMD" > "$PORT"
    sleep "${2:-1.5}"
    cat "$PORT" &
    PID=$!
    sleep 2
    kill "$PID" 2>/dev/null
}

# === SERIAL CONFIG
BAUD_RATE=115200
PORT=$(detect_serial_port)
stty -F "$PORT" $BAUD_RATE cs8 -cstopb -parenb -ixon -crtscts


# === BEGIN COMMAND SEQUENCE ===
echo "Using port $PORT on $PLATFORM with $BAUD_RATE baud rate"

send_command ""
sleep 1

echo "Removing previous configs..."
send_command "rm -f /lib/systemd/network/51-wireless.network"
send_command "rm -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

echo "Creating networkd config..."
send_command "mkdir -p /lib/systemd/network"
send_command "echo '[Match]' > /lib/systemd/network/51-wireless.network"
send_command "echo 'Name=wlan0' >> /lib/systemd/network/51-wireless.network"
send_command "echo '[Network]' >> /lib/systemd/network/51-wireless.network"
send_command "echo 'DHCP=ipv4' >> /lib/systemd/network/51-wireless.network"

echo "Bringing up wlan0 and scanning..."
send_command "ifconfig wlan0 up"
send_command "iw dev wlan0 scan | grep SSID" 2

echo "Creating WPA config..."
send_command "mkdir -p /etc/wpa_supplicant/"
send_command "echo 'ctrl_interface=/var/run/wpa_supplicant' > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
send_command "echo 'eapol_version=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
send_command "echo 'ap_scan=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
send_command "echo 'fast_reauth=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
send_command "wpa_passphrase '$SSID' '$PASSWORD' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

echo "Restarting services..."
send_command "systemctl enable wpa_supplicant@wlan0.service"
send_command "systemctl restart systemd-networkd.service"
send_command "systemctl restart wpa_supplicant@wlan0.service"

echo "Waiting for connection..."
sleep 15

echo "Checking connectivity..."
send_and_print_output "ping -c 4 8.8.8.8" 6

echo "Done."
