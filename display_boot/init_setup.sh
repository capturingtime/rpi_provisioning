#!/bin/bash
# Base Setup on fresh raspbian light

# Get mac address of Wlan0
mac=$(cat /sys/class/net/wlan0/address | sed 's/://g')
# Use mac in name, set at end of process.
hostname="ctp-display-${mac}"
timezone='America/Los_Angeles'

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
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setting hostname to ${hostname}"
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
    if [ $i > 0 ]; then
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
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running Apt Upgrade (This takes a while, 15-20m)"
sudo apt-get dist-upgrade -qq -y > /dev/null

#
# raspi-config
#
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Configure Raspberry Pi"
# https://raspberrypi.stackexchange.com/questions/28907/how-could-one-automate-the-raspbian-raspi-config-setup

# Set "Boot to CLI"
sudo raspi-config nonint do_boot_behaviour B1
# Set 'dont wait for network at boot'
# sudo raspi-config nonint do_boot_wait 0
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
# Disable Serial
sudo raspi-config nonint do_serial 0
# Disable 1-Wire
sudo raspi-config nonint do_onewire 0
# Disable GPIO remote pins
sudo raspi-config nonint do_rgpio 0
# Set GPU Mem split to 16MB
sudo raspi-config nonint do_memory_split 16
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

# Copy marketing image
sudo cp /boot/resources/display_marketing_1.jpg /opt/

# Disable services that aren't needed (free resources, reduce boot time)
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Disabling services not required (Performance)"
sudo systemctl disable autovt@.service
sudo systemctl disable dphys-swapfile.service
sudo systemctl disable fake-hwclock.service
sudo systemctl disable getty@.service
sudo systemctl disable ifupdown-wait-online.service
sudo systemctl disable keyboard-setup.service
sudo systemctl disable rsyslog.service
sudo systemctl disable serial-getty@.service
sudo systemctl disable raspi-config.service
sudo systemctl disable hciuart.service # Bluetooth
sudo systemctl disable bluetooth.service
sudo systemctl disable bthelper@hci0.service
sudo systemctl disable avahi-daemon.service # https://www.thegeekdiary.com/linux-os-service-avahi-daemon/
sudo systemctl disable rsync.service
sudo systemctl disable chrony-wait.service
sudo systemctl disable systemd-udev-trigger.service # "hotplug" manager, that allows you to plug in USB devices

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

# Signage service
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Install and configure 'Signage' service"
sudo cp /boot/resources/ctp_signage /usr/bin/
sudo chmod a+x /usr/bin/ctp_signage

sudo sh -c "cat <<EOF > /lib/systemd/system/ctp_signage_event.service
[Unit]
Description=Uses fbi to display images in /opt/booth_images

[Service]
Type=simple
ExecStart=/bin/bash /usr/bin/ctp_signage /opt/booth_images
ExecStopPost=dd if=/dev/zero of=/dev/fb0
Nice=10

[Install]
WantedBy=multi-user.target
EOF
"
sudo ln -s /lib/systemd/system/ctp_signage_event.service /etc/systemd/system/ctp_signage_event.service
# Started after provisioning

# setup 'first boot' logic for self provisioning
# echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Setup for provisioning on next boot"

# sudo cp /boot/resources/provision_display /usr/bin/
# sudo chmod a+x /usr/bin/provision_display

# sudo sh -c "cat <<EOF > /lib/systemd/system/provision_display.service
# [Unit]
# Description=Runs after newely provisioned display pi comes up for the first time. Disables service after execution

# [Service]
# Type=oneshot
# ExecStart=/bin/bash /usr/bin/provision_display

# [Install]
# WantedBy=multi-user.target
# EOF
# "
# sudo ln -s /lib/systemd/system/provision_display.service /etc/systemd/system/provision_display.service
# sudo systemctl enable provision_display.service

#
# Below copied from provision_display, just easier for now.
#

# Show something on screen
# sudo /usr/bin/fbi -d /dev/fb0 -T 1 -1 --noverbose -a -u /boot/resources/provision.jpg

# Modify Networking Stack
echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Modify the network stack"
sudo cp /etc/systemd/system/dhcpcd.service.d/wait.conf /etc/systemd/system/dhcpcd.service.d/wait.conf.dist
sudo sed -i 's|/dhcpcd -q -w|/dhcpcd -q|' /etc/systemd/system/dhcpcd.service.d/wait.conf

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
    /boot/install_setup_syncthing.sh -p "${st_gui_pw}" -m "display"
fi

# Enable the signage service that actually displays content
sudo systemctl enable ctp_signage_event.service

# Disable the service that called this, because we only want to run it once
# sudo systemctl disable provision_display.service

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Running Apt AutoClean"
sudo apt-get autoremove -qq -y > /dev/null
sudo apt-get autoclean -qq -y > /dev/null

echo "$(stamp) DEPLOYMENT SCRIPT (L${LINENO}): Display Deployment Complete"

# Reboot in 1 min
sudo reboot
