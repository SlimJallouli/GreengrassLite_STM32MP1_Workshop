# USER CONFIGURATION
$SSID = "YOUR_WIFI_SSID"
$PASSWORD = "YOUR_WIFI_PASSWORD"

# Find STM32 serial port by querying Win32_SerialPort WMI class
function Get-Stm32SerialPort {
    $candidatePorts = Get-WmiObject Win32_SerialPort | Where-Object { $_.Description -match "STM|STMicro" }
    if (-not $candidatePorts) {
        Write-Error "No STM32-related serial ports found."
        exit 1
    }

    foreach ($port in $candidatePorts) {
        $portName = $port.DeviceID
        Write-Host "Probing $portName..."
        try {
            $serial = New-Object System.IO.Ports.SerialPort $portName, 115200, 'None', 8, 'One'
            $serial.ReadTimeout = 1000
            $serial.WriteTimeout = 1000
            $serial.Open()
            Start-Sleep -Milliseconds 300

            # Clear buffer
            while ($serial.BytesToRead -gt 0) { $null = $serial.ReadExisting() }

            # Send test command
            $serial.WriteLine("uname -a")
            Start-Sleep -Milliseconds 500

            $response = ""
            $start = Get-Date
            while (((Get-Date) - $start).TotalSeconds -lt 2) {
                try {
                    $line = $serial.ReadLine()
                    if ($line) {
                        $response += $line + "`n"
                    }
                } catch [System.TimeoutException] {}
            }

            if ($response -like "*Linux*") {
                Write-Host "$portName responded like a Linux shell:"
                $serial.Close()
                return $portName
            } else {
                Write-Host "$portName did not respond as expected."
                $serial.Close()
            }
        } catch {
            Write-Warning "Failed to probe $portName : $_"
        }
    }

    Write-Error "No valid STM32 Linux shell found on available serial ports."
    exit 1
}


# Open serial port and return System.IO.Ports.SerialPort object
function Open-SerialPort {
    param (
        [string]$PortName,
        [int]$BaudRate = 115200
    )
    $port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
    $port.ReadTimeout = 3000
    $port.WriteTimeout = 3000
    $port.Open()
    return $port
}

# Send a command string to serial port (with CRLF)
function Send-Command {
    param (
        [System.IO.Ports.SerialPort]$Port,
        [string]$Command
    )
    Write-Host ">>> $Command"
    $Port.WriteLine($Command)
    Start-Sleep -Milliseconds 500
}

# Send a command and read response lines for a specified time
function Send-And-Read {
    param (
        [System.IO.Ports.SerialPort]$Port,
        [string]$Command,
        [int]$ReadDurationSec = 2
    )
    Send-Command -Port $Port -Command $Command
    $endTime = (Get-Date).AddSeconds($ReadDurationSec)
    while ((Get-Date) -lt $endTime) {
        try {
            $line = $Port.ReadLine()
            if ($line) {
                Write-Host $line
            }
        }
        catch [TimeoutException] {
            # No data ready, just continue waiting
        }
    }
}

# Main
$portName = Get-Stm32SerialPort
Write-Host "Using serial port: $portName at 115200 baud"

$port = Open-SerialPort -PortName $portName -BaudRate 115200

# Wait a moment
Start-Sleep -Seconds 1

# Start command sequence
Send-Command -Port $port -Command ""

Write-Host "Removing previous configs..."
Send-Command -Port $port -Command "rm -f /lib/systemd/network/51-wireless.network"
Send-Command -Port $port -Command "rm -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

Write-Host "Creating networkd config..."
Send-Command -Port $port -Command "mkdir -p /lib/systemd/network"
Send-Command -Port $port -Command "echo '[Match]' > /lib/systemd/network/51-wireless.network"
Send-Command -Port $port -Command "echo 'Name=wlan0' >> /lib/systemd/network/51-wireless.network"
Send-Command -Port $port -Command "echo '[Network]' >> /lib/systemd/network/51-wireless.network"
Send-Command -Port $port -Command "echo 'DHCP=ipv4' >> /lib/systemd/network/51-wireless.network"

Write-Host "Bringing up wlan0 and scanning..."
Send-Command -Port $port -Command "ifconfig wlan0 up"
Send-And-Read -Port $port -Command "iw dev wlan0 scan | grep SSID" -ReadDurationSec 4

Write-Host "Creating WPA config..."
Send-Command -Port $port -Command "mkdir -p /etc/wpa_supplicant/"
Send-Command -Port $port -Command "echo 'ctrl_interface=/var/run/wpa_supplicant' > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
Send-Command -Port $port -Command "echo 'eapol_version=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
Send-Command -Port $port -Command "echo 'ap_scan=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
Send-Command -Port $port -Command "echo 'fast_reauth=1' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
Send-Command -Port $port -Command "wpa_passphrase '$SSID' '$PASSWORD' >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

Write-Host "Restarting services..."
Send-Command -Port $port -Command "systemctl enable wpa_supplicant@wlan0.service"
Send-Command -Port $port -Command "systemctl restart systemd-networkd.service"
Send-Command -Port $port -Command "systemctl restart wpa_supplicant@wlan0.service"

Write-Host "Waiting for connection..."
Start-Sleep -Seconds 15

Write-Host "Checking connectivity..."
Send-And-Read -Port $port -Command "ping -c 4 8.8.8.8" -ReadDurationSec 6

Write-Host "Done."

$port.Close()
