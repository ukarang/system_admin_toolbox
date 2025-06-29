#!/bin/sh

# Define variables
nasaddress="tnas1.den1.nas.nas"
site="DEN1"
host="web1"
config_path="/backup/${host}/config"
db_path="/backup/${host}/db"
data_path="/backup/${host}/data"
log_file="/var/log/backup.log"

# Mount NAS
mount $nasaddress:/mnt/z/nfs0/backup/$site /backup || { echo "Mount failed! Exiting."; exit 1; }

# Create necessary directories
mkdir -p $config_path $db_path/d $db_path/w $db_path/m $data_path

# Backup Config files
echo "Backing up config files..." >> $log_file
cd $config_path
tar -zcvf etc.tgz /etc || { echo "Config backup failed"; exit 1; }
tar -zcvf home.tgz /usr/home
tar -zcvf root.tgz /root
tar -zcvf usrlocaletc.tgz /usr/local/etc
cp /boot/loader.conf .
df -h > df.txt
zfs list > zfslist.txt
zpool list > zpoollist.txt
ifconfig -a > ifconfig.txt
ip address > ipaddress.txt
pkg info > pkg.txt
apt list --installed > apt-list.txt
uname -a > uname.txt
mount > mount.txt

# DB Backup
echo "Backing up databases..." >> $log_file
cd $db_path/d
mysqldump -h mydb1.systems.com -u master -p'password' -master > "-master_`date '+%Y-%m-%d'`.sql"
mysqldump -h mydb1.systems.com -u service -p'password' service > "service_`date '+%Y-%m-%d'`.sql"
find . -mindepth 1 -maxdepth 1 -mtime +2 -exec mv -t /$db_path/w {} +
find . -mindepth 1 -maxdepth 1 -mtime +3 -exec mv -t /$db_path/m {} +

# Data Backup
echo "Backing up data files..." >> $log_file
cd $data_path
tar -zcvf "$site_etc_`date '+%Y-%m-%d'`.tgz" /usr/local/etc
tar -zcvf "$site_www_`date '+%Y-%m-%d'`.tgz" /usr/local/www

# Optional directories to backup
# tar -zcvf acme.tgz /var/db/acme
# tar -zcvf www.tgz /usr/local/www

# Database Cleanup
echo "Cleaning up old DB backups..." >> $log_file
find /$db_path/d/* -mtime +3 -exec rm {} \;
find /$db_path/w/* -mtime +21 -exec rm {} \;
find /$db_path/m/* -mtime +90 -exec rm {} \;

# Unmount NAS
umount /backup || { echo "Unmount failed!"; exit 1; }

echo "Backup complete." >> $log_file
