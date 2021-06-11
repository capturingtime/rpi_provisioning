#!/bin/bash
# Base Setup on fresh raspbian light

# Get mac address of Wlan0
mac=$(cat /sys/class/net/wlan0/address | sed 's/://g')
# Use mac in name, set at end of process.
hostname="ctp-booth-${mac}"
timezone='America/Los_Angeles'
branch='main' # Branch for photobooth package

requirements='chromium-browser gphoto2 unclutter matchbox-window-manager'

function stamp()
{
   echo $(date +%Y%m%dT%H%M%S%z)
}

# Change PI password
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Update user: pi's password"
if [ -f "/boot/u_pi_pass" ]; then
    u_pi_pass=$(cat /boot/u_pi_pass)
    sudo chpasswd <<< "pi:${u_pi_pass}"
    sudo rm /boot/u_pi_pass
fi

# Set static IP (fallback)
if [ -f "/boot/static_ip" ]; then
    echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Static IP fallback config found, applying."
    # Set a static ip on the wireless adapter
    sudo cp /etc/dhcpcd.conf /etc/dhcpcd.conf.dist
    sudo sh -c "cat /boot/static_ip >> /etc/dhcpcd.conf"
    sudo systemctl restart dhcpcd.service
    sudo systemctl restart networking
fi

# Set Hostname
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setting hostname to ${hostname} (ignore the error)"
sudo hostnamectl set-hostname "${hostname}"
sudo sh -c "cat <<EOF >> /etc/hosts
127.0.1.1       ${hostname}
EOF
"

# Set Timezone
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setting timezone to ${timezone}"
sudo timedatectl set-timezone ${timezone}

# Wait for internet
i=30
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Waiting up to ${i} seconds for internet connectivity"
while :; do
    wget -q --spider http://google.com
    if [ $? -eq 0 ]; then
        break
    fi
    if [[ $i > 0 ]]; then
        ((i=i-1))
        sleep 1
    else
        echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Internet connectivity is not available. Exiting..."
        exit 1
    fi
done

# Remove / Update / Upgrade
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running Apt Update"
sudo apt-get update -qq -y > /dev/null
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running Apt Upgrade (This takes a while, 10-15m)"
sudo apt-get dist-upgrade -qq -y > /dev/null
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Installing required packages"
sudo apt-get install -y -qq ${requirements} > /dev/null

#
# raspi-config
#
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Configure Raspberry Pi"
# https://raspberrypi.stackexchange.com/questions/28907/how-could-one-automate-the-raspbian-raspi-config-setup

# Set "Boot to CLI"
sudo raspi-config nonint do_boot_behaviour B1
# Set 'dont wait for network at boot'
# sudo raspi-config nonint do_boot_wait 0
# Disable Boot Splash
sudo raspi-config nonint do_boot_splash 1
# Set overscan compensation
sudo raspi-config nonint do_overscan 1
# Disable camera port
sudo raspi-config nonint do_camera 0
# Enable SSH
sudo raspi-config nonint do_ssh 1
sudo systemctl enable ssh.service # Not sure why this is needed, but it is.
# Disable I2C
sudo raspi-config nonint do_i2c 0
# Disable SPI
sudo raspi-config nonint do_spi 0
# Set WiFi Country Code (Wireless frequency compliance)
sudo raspi-config nonint do_wifi_country US


# Set Localization options
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setting localization"
# https://gist.github.com/adoyle/71803222aff301da9662
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
sudo cp /etc/locale.gen /etc/locale.gen.dist
sudo sed -i -e "/^[^#]/s/^/#/" -e "/en_US.UTF-8/s/^#//" /etc/locale.gen
sudo cp /var/cache/debconf/config.dat /var/cache/debconf/config.dat.dist
sudo sed -i -e "/^Value: en_GB.UTF-8/s/en_GB/en_US/" -e "/^ locales = en_GB.UTF-8/s/en_GB/en_US/" /var/cache/debconf/config.dat
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8
sudo raspi-config nonint do_configure_keyboard us

# Modify /boot/cmdline.txt
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Modifying /boot/cmdline.txt"
sudo cp /boot/cmdline.txt /boot/cmdline.txt.bak
# Disable File system check (boot speed)
sudo sed -i 's/fsck.repair=yes/fsck.repair=no/' /boot/cmdline.txt
# Set cmdline variables
# logo.nologo vt.global_cursor_default=0 consoleblank=0 loglevel=1
sudo sed -i -e 's/$/ noatime nodiratime logo.nologo vt.global_cursor_default=0 consoleblank=0 loglevel=1 quiet splash plymouth.ignore-serial-consoles/' /boot/cmdline.txt
# Change console output to tty3 instead of tty1. (doesn't print terminal to screen)
sudo sed -i 's/console=tty1/console=tty3/' /boot/cmdline.txt

# setup Splash
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Install and configure splash"

sudo cp /boot/resources/splash.png /opt/splash.png
sudo chmod 644 /opt/splash.png
sudo sh -c "cat <<EOF >> /lib/systemd/system/splash.service
[Unit]
Description=boot splash screen

DefaultDependencies=no
After=local-fs.target

[Service]

StandardInput=tty
StandardOutput=tty

ExecStart=/usr/bin/fbi -1 --noverbose -a /opt/splash.png
ExecStartPost=/bin/sleep 5

[Install]
WantedBy=sysinit.target
EOF
"

sudo ln -s /lib/systemd/system/splash.service /etc/systemd/system/splash.service
# sudo systemctl enable splash.service # Disabling for now.

# Disable services that aren't needed (free resources, reduce boot time)
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Disabling services not required (Performance)"
# sudo systemctl disable autovt@.service
# sudo systemctl disable dphys-swapfile.service
# sudo systemctl disable fake-hwclock.service
# sudo systemctl disable getty@.service
# sudo systemctl disable ifupdown-wait-online.service
# sudo systemctl disable keyboard-setup.service
# sudo systemctl disable rsyslog.service
# sudo systemctl disable serial-getty@.service
# sudo systemctl disable raspi-config.service
# sudo systemctl disable hciuart.service # Bluetooth
# sudo systemctl disable bluetooth.service
# sudo systemctl disable bthelper@hci0.service
# sudo systemctl disable avahi-daemon.service # https://www.thegeekdiary.com/linux-os-service-avahi-daemon/
# sudo systemctl disable rsync.service
# sudo systemctl disable chrony-wait.service
# sudo systemctl disable systemd-udev-trigger.service # "hotplug" manager, that allows you to plug in USB devices

# Modify /boot/config.txt
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Modify /boot/config.txt"

sudo sed -i 's/dtparam=i2c_arm=on/#dtparam=i2c_arm=on/' /boot/config.txt
sudo sed -i 's/dtparam=spi=on/#dtparam=spi=on/' /boot/config.txt
sudo sed -i 's/dtparam=audio=on/dtparam=audio=off/' /boot/config.txt
sudo sed -i 's/start_x=1/start_x=0/' /boot/config.txt

# Append missing items
sudo sh -c "cat <<EOF >> /boot/config.txt
# Custom
# Disable the rainbow splash screen
disable_splash=1
# Set the bootloader delay to 0 seconds. The default is 1s if not specified.
boot_delay=0
# Disable Bluetooth
dtoverlay=disable-bt
dtoverlay=pi3-disable-bt
EOF
"

# Install FBI
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Install fbi (framebuffer image viewer)"
sudo apt-get install -qq -y fbi > /dev/null

# Modify Networking Stack
# echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Modify the network stack"
# sudo cp /etc/systemd/system/dhcpcd.service.d/wait.conf /etc/systemd/system/dhcpcd.service.d/wait.conf.dist
# sudo sed -i 's|/dhcpcd -q -w|/dhcpcd -q|' /etc/systemd/system/dhcpcd.service.d/wait.conf

# pre-populate github.com ssh
# echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Key Scanning github.com and populating ~/.ssh/known_hosts"
# mkdir -p ~/.ssh
# ssh-keyscan -H github.com >> ~/.ssh/known_hosts
# sudo cp ~/.ssh/known_hosts /root/.ssh/known_hosts

# Manage python
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Install python3-pip"
sudo apt-get install -y -qq python3-pip > /dev/null
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Install photobooth package (branch: ${branch})"
sudo pip3 install -e git+https://github.com/capturingtime/photobooth.git@${branch}#egg=photobooth > /dev/null
sudo pip3 install pyzenfolio
# sudo wget --quiet -O /opt/booth_init.py \
    # https://raw.githubusercontent.com/capturingtime/photobooth/extend_framework/examples/booth_init.py
sudo cp /boot/resources/run_booth.py /opt/
sudo cp /boot/resources/clear_booth.py /opt/

# Install and setup SyncThings
if [ -f "/boot/st_gui_pw" ]; then
    st_gui_pw=$(cat /boot/st_gui_pw)
    sudo rm /boot/st_gui_pw
fi

if [ -f "/boot/syncthing_device_mgr" ]; then
    sudo cp /boot/syncthing_device_mgr /usr/bin
    sudo chmod a+x /boot/syncthing_device_mgr
fi

if [ -f "/boot/install_setup_syncthing.sh" ]; then
    /boot/install_setup_syncthing.sh -p "${st_gui_pw}" -m "hub"
fi

# Read Zenfolio API password
if [ -f "/boot/zen_api_pw" ]; then
    zen_api_pw=$(cat /boot/zen_api_pw)
    sudo rm /boot/zen_api_pw
fi

# Create service file for booth script
sudo sh -c "cat <<EOF >> /lib/systemd/system/booth.service
[Unit]
Description=Booth Code

DefaultDependencies=no
After=network.target

[Service]
Type=simple
StandardInput=tty
StandardOutput=tty

User=root
Group=root

ExecStart=python3 /opt/run_booth.py -x -u ctpapi -p ${zen_api_pw}
ExecStopPost=python3 /opt/clear_booth.py

[Install]
WantedBy=default.target
EOF
"
sudo ln -s /lib/systemd/system/booth.service /etc/systemd/system/booth.service
sudo systemctl enable booth.service

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running Apt AutoClean"
sudo apt-get autoremove -qq -y > /dev/null
sudo apt-get autoclean -qq -y > /dev/null

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Booth Deployment Complete"

# Reboot in 1 min
sudo reboot
