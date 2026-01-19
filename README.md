# Spd_dump_termux
Use spd_dump tool on a rooted device 

DISCLAIMER:
```
/* * I'm not responsible for bricked devices, dead SD cards, thermonuclear war, or you getting fired because the alarm app failed (like it did for me...). * Please do some research if you have any concerns about features included in the products you find here before flashing it! * YOU are choosing to make these modifications, and if you point the finger at me for messing up your device, I will laugh at you. * Your warranty will be void if you tamper with any part of your device / software. *  */
```
REQUIREMENTS:

•A ROOTED PHONE

•TERMUX

•INTERNET CONNECTION

First Setup Chroot by [following this tuturial](Chroot_tuturial.md)
```
apt update && apt upgrade -y 
```
Wait until it install and then install the drivers
```
sudo apt-get install build-essential libusb-1.0-0-dev git wget curl unzip zip
```
```
curl -L -O https://github.com/Seuj09/Spd_dump_termux/releases/download/Release/spreadtrum_flash_termux.zip
```
```
unzip spreadtrum_flash_termux.zip
```
```
cd spreadtrum_flash_termux
```
```
chmod +x spd_dump
chmod +x menu.sh
chmod +x gen_spl-unlock
chmod +x gen_spl-unlock-legacy
chmod +x gen_fdl1-dl
chmod +x misc-fastbootd.bin
chmod +x misc-wipe.bin
```

# Usage
Run the menu then choose your phone, and chipset. A menu will appear and choose the option you want

```
./menu.sh
```
