First install termux apk from github or fdroid

Second install busybox

# grant root permission for the app and type su to grant root permission

# Create a new directory called chrootubuntu in /data/local/tmp

mkdir /data/local/tmp/chrootubuntu

cd /data/local/tmp/chrootubuntu

# Get the ubuntu 22 rootfs

busybox wget https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz

alternative if that has errors:

busybox curl https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz --output ubuntu-base-22.04-base-arm64.tar.gz

# Extract the file and create needed directories

tar xvf ubuntu-base-22.04-base-arm64.tar.gz

mkdir dev/shm

mkdir sdcard

cd ../

# Create a new file called start.sh and add this script(youll have to google how to use vi first so that you wont get confused)
vi start.sh

# Type I(dont enter) then paste this
(start from #!/bin/sh to busybox chroot $UBUNTUPATH /bin/su - root
)

#!/bin/sh

#The path of ubuntu rootfs
UBUNTUPATH="/data/local/tmp/chrootubuntu"

#Make needed files AGAIN
mkdir $UBUNTUPATH/sdcard
mkdir $UBUNTUPATH/dev/shm

#Fix setuid issue
busybox mount -o remount,dev,suid /data

busybox mount --bind /dev $UBUNTUPATH/dev
busybox mount --bind /sys $UBUNTUPATH/sys
busybox mount --bind /proc $UBUNTUPATH/proc
busybox mount -t devpts devpts $UBUNTUPATH/dev/pts

#/dev/shm for Electron apps
busybox mount -t tmpfs -o size=256M tmpfs $UBUNTUPATH/dev/shm

#Mount sdcard
busybox mount --bind /sdcard $UBUNTUPATH/sdcard

#chroot into Ubuntu
busybox chroot $UBUNTUPATH /bin/su - root

# exit vi and execute the file

Press ESC then :qw to save and exit

after going back to termux type
chmod +x start.sh
./start.sh

command will change from # to root@localhost#/

# type these last commands to solve some issues and install necessary libraries 

echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "127.0.0.1 localhost" > /etc/hosts

groupadd -g 3003 aid_inet
groupadd -g 3004 aid_net_raw
groupadd -g 1003 aid_graphics
usermod -g 3003 -G 3003,3004 -a _apt
usermod -G 3003 -a root

apt update
apt upgrade

apt install nano vim net-tools sudo git

# Install the needed libraries and files in Readme.md 

