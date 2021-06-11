#!/bin/bash

# This script installs syncthing with slightly different setup for Booth Vs Hub

# Notes to delete later
# https://www.garron.me/en/linux/add-secondary-ip-linux.html
# https://unix.stackexchange.com/questions/197636/run-an-arbitrary-command-when-a-service-fails

function stamp()
{
   echo $(date +%Y%m%dT%H%M%S%z)
}

function wait-api(){
    # Check Syncthing API is ready
    while :
    do
        v=$(syncthing cli show version | jq -r '.version' | cut -d'v' -f2)
        if [ "${v}" != "${ver}" ]; then
            echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Syncthing is not ready, sleeping for 5s..."
            sleep 5
            continue
        fi

        my_api_key=$(syncthing cli config gui apikey get)

        if [[ $my_api_key =~ ^[a-zA-Z0-9]+$ ]]; then
            result=$(curl -X GET -w "%{http_code}" -sS -o /dev/null -k -H "X-API-Key: ${my_api_key}" \
                    https://127.0.0.1:${https_port}/rest/system/ping)
            if [ "$result" != "200" ]; then
                echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Syncthing API is not ready, sleeping for 5s..."
                sleep 5
            else
                break
            fi
        else
            echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): API Key failed validation, sleeping for 5s and trying again..."
            sleep 5
            continue
        fi
    done
}

# Requirements
dependency_list="jq apt-transport-https"

# Defaults for input KWargs
op_user="pi"
gui_user="ctpadmin"
gui_pass=""
https_port='8384'
mode="display"
ver="1.18.1"

# Other Vars
root_path="/opt"
share_folders=(booth_images)

while getopts :u:p:k:m:o:i:t:v: flag
do
    case $flag in
        u)
            # The user to set for the GUI
            gui_user=$OPTARG
            ;;
        p)
            # The password to set the GUI user to
            gui_pass=$OPTARG
            ;;
        m)
            # Mode should be 'display' or 'hub'
            mode=$OPTARG
            ;;
        o)
            # operational user for the system that syncthing service will run under
            op_user=$OPTARG
            ;;
        t)
            # HTTPS port to use
            https_port=$OPTARG
            ;;
        v)
            # version to use
            ver=$OPTARG
            ;;
        ?)
            #Didn't find that flag
            echo "ERROR: Unrecognized option"
            exit 0;;
    esac
done

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Starting Syncthing install and configure"

# Check that mode is either "hub" or "display"
if [[ "$mode" == "hub" || "$mode" == "display" ]]; then
    echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running as mode: ${mode}"
else
    echo "Mode must be one of: 'hub' or 'display'."
    exit 1
fi

if [ -z "gui_pass" ]; then
    echo "Warning: no GUI Password set. Access to GUI will be unsecured"
fi

# Setup system folders
for dir in "${share_folders[@]}"; do
    # FIXME: Check if dir already exists, skip and warn
    sudo mkdir -p ${root_path}/${dir}
    sudo chown ${op_user}:${op_user} ${root_path}/${dir}
done


# Setup package repo
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Configuring package repo for apt"
# https://apt.syncthing.net/
# Add the release PGP keys:
sudo curl -s -o /usr/share/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
# Add the "stable" channel to your APT sources:
echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | sudo tee /etc/apt/sources.list.d/syncthing.list
# Increase preference of Syncthing's packages ("pinning")
printf "Package: *\nPin: origin apt.syncthing.net\nPin-Priority: 990\n" | sudo tee /etc/apt/preferences.d/syncthing

# Update and install syncthing:
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Installing syncthing from added repo"
sudo apt-get update -qq -y > /dev/null
sudo apt-get install -qq -y ${dependency_list} > /dev/null
sudo apt-get install -qq -y syncthing=${ver} > /dev/null

# Create, Enable, and start Syncthing service
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Installing syncthing service"
sudo sh -c "cat <<EOF > /lib/systemd/system/syncthing@.service
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization for %I
Documentation=man:syncthing(1)
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=4

[Service]
User=%i
ExecStart=/usr/bin/syncthing serve --no-browser --no-restart --logflags=0
Restart=on-failure
RestartSec=1
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

# Hardening
ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
"

sudo ln -s /lib/systemd/system/syncthing@.service /etc/systemd/system/syncthing@.service
sudo systemctl enable syncthing@${op_user}.service
sudo systemctl start syncthing@${op_user}.service

# Make sure the api is ready
wait-api

#
# Config
#
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setting syncthing to listen on all interfaces"
# listen all adapters
syncthing cli config gui raw-address set 0.0.0.0:8384


echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Configuring syncthing"
# There is a race condition if we don't wait for the API to be ready after changing the listening address.
wait-api

# Set gui user/pass
syncthing cli config gui user set "${gui_user}"
syncthing cli config gui password set "${gui_pass}"
# GUI Theme
syncthing cli config gui theme set dark
# Configure Options
syncthing cli config options relays-enabled set false
syncthing cli config options start-browser set false
syncthing cli config options natenabled set false
syncthing cli config options global-ann-enabled set false
# Use SSL/TLS
syncthing cli config gui raw-use-tls set true && sleep 1 # Give sync thing a moment to process

# setup folders
syncthing cli config folders default delete
for dir in "${share_folders[@]}"; do
    syncthing cli config folders add \
      --label ${dir} \
      --id ${dir} \
      --path ${root_path}/${dir}
    # Displays should have this folder set to receive-only
    if [[ $mode == "display" ]]; then
        syncthing cli config folders ${dir} type set receiveonly
    fi
done

# Create, Enable, and start Syncthing 'device manager' service
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Installing syncthing device management service"
sudo sh -c "cat <<EOF > /lib/systemd/system/syncthing_device_mgr@.service
[Unit]
Description=Syncthing Device Manager - Detect changes to devices
After=network.target syncthing@${op_user}.service
StartLimitIntervalSec=60

[Service]
User=%i
ExecStart=/usr/bin/syncthing_device_mgr
Restart=on-failure
RestartSec=30
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

# Hardening
ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
"
sudo ln -s /lib/systemd/system/syncthing_device_mgr@.service /etc/systemd/system/syncthing_device_mgr@.service
sudo systemctl enable syncthing_device_mgr@${op_user}.service
# sudo systemctl start syncthing_device_mgr@${op_user}.service

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Syncthing install and configure: Complete"
