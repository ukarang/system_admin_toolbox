#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Backup script for Debian Linux
# Version: 4.2
# Usage: Run as root by cron

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Lock to prevent concurrent runs
exec 200>/var/lock/backup.lock
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Another backup instance is already running. Exiting." >&2
    exit 1
fi

# Site-specific configuration
nasaddress="tnas1.den1.nas.nas"
site="DEN1"
host="$(hostname -s)"

# Directory paths for backup destinations
config_path="/backup/${host}/config"
db_path="/backup/${host}/db"
data_path="/backup/${host}/data"
daily_dir="${db_path}/daily"
weekly_dir="${db_path}/weekly"
monthly_dir="${db_path}/monthly"

# Log files
log_file="/var/log/backup.log"
error_log="/var/log/backup-error.log"

# NFS configuration
nfs_remote="/mnt/z/nfs0/backup/${site}"
nfs_local="/backup"

# Date variables
today="$(date +%F)"
dow="$(date +%u)"  # 1 = Monday, 7 = Sunday
dom="$((10#$(date +%d)))"  # Day of month without leading zero

# Compression command
compress_cmd="$(command -v pigz || echo gzip)"

# MySQL credentials file
mysql_config="/root/.my.cnf"

# Admin email for notifications
admin_email="ukarang@ukarang.com"

# Max log file size before rotation
max_log_size=10485760

# Retention policies
DAILY_RETENTION=3
WEEKLY_KEEP=3
MONTHLY_KEEP=3
DATA_RETENTION=30

# Log a regular message
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

# Log an error message
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "$log_file" "$error_log" >&2
}

# Rotate logs if size exceeds max_log_size
rotate_log() {
    if [[ -f "$log_file" ]] && [[ $(stat -c%s "$log_file") -gt $max_log_size ]]; then
        mv "$log_file" "$log_file.old"
        touch "$log_file"
    fi
    if [[ -f "$error_log" ]] && [[ $(stat -c%s "$error_log") -gt $max_log_size ]]; then
        mv "$error_log" "$error_log.old"
        touch "$error_log"
    fi
}

# Send email notifications
send_notification() {
    local status="$1"
    local message="$2"
    if command -v mail >/dev/null 2>&1 && [[ -n "$admin_email" ]]; then
        echo "$message" | mail -s "Backup $status: $host - $(date)" "$admin_email" 2>/dev/null || true
    fi
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if mountpoint -q "$nfs_local" 2>/dev/null; then
        log_message "Cleaning up: unmounting NFS"
        umount "$nfs_local" 2>/dev/null || log_error "Failed to unmount $nfs_local"
    fi
    if [[ $exit_code -ne 0 ]]; then
        log_error "Backup script failed with exit code $exit_code"
        send_notification "FAILED" "Backup failed on $host at $(date). Check logs for details."
    fi
}
trap cleanup EXIT INT TERM

# Ensure script is run as root
check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Install required packages if not present
install_prerequisites() {
    log_message "Checking and installing prerequisites..."
    local packages_to_install=()
    for pkg in nfs-common mailutils pigz; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            packages_to_install+=("$pkg")
        fi
    done
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        apt-get update && apt-get install -y "${packages_to_install[@]}"
    fi
}

# Mount the NAS backup target
mount_nas() {
    mkdir -p "$nfs_local" "$config_path" "$daily_dir" "$weekly_dir" "$monthly_dir" "$data_path"
    if mountpoint -q "$nfs_local"; then
        log_message "NFS already mounted"
        return
    fi
    ping -c 1 -W 5 "$nasaddress" >/dev/null || { log_error "Cannot reach NAS"; exit 1; }
    timeout 30 mount -t nfs -o vers=4,rw,hard,intr,timeo=30,retrans=2 "$nasaddress:$nfs_remote" "$nfs_local" || {
        log_error "Failed to mount NFS"
        exit 1
    }
    touch "$nfs_local/.backup_test" || { log_error "NFS not writable"; exit 1; }
    rm -f "$nfs_local/.backup_test"
}

# Backup key configuration directories and logs
backup_configs() {
    log_message "Backing up system configuration files..."
    for dir in etc home root usr/local/etc opt; do
        [ -e "/$dir" ] && tar -czf "$config_path/${dir//\//-}-$host-$today.tgz" -C / "$dir"
    done
    cp /boot/grub/grub.cfg "$config_path/grub-$host-$today.cfg" 2>/dev/null || true
    dpkg -l > "$config_path/dpkg-$host-$today.txt"
    ip addr > "$config_path/ip-$host-$today.txt"
    mount > "$config_path/mounts-$host-$today.txt"
    df -h > "$config_path/df-$host-$today.txt"
    uname -a > "$config_path/uname-$host-$today.txt"
    systemctl list-enabled > "$config_path/services-$host-$today.txt"
    crontab -l > "$config_path/crontab-$host-$today.txt" 2>/dev/null || true
    tar -czf "$config_path/logs-$host-$today.tgz" -C / var/log
}

# Backup MySQL databases
backup_databases() {
    log_message "Backing up MySQL databases..."
    for db in master service; do
        local dump="$daily_dir/${db}-${today}.sql"
        mysqldump --defaults-file="$mysql_config" -h mydb1.systems.com --single-transaction --routines --triggers "$db" > "$dump"
        $compress_cmd "$dump"
    done
    find "$daily_dir" -type f -name "*.sql.gz" -mtime +$DAILY_RETENTION -delete
}

# Create weekly and monthly snapshots of DB backups
create_snapshots() {
    if [[ $dow -eq 7 ]]; then
        log_message "Creating weekly snapshots..."
        for db in master service; do
            cp "$daily_dir/${db}-${today}.sql.gz" "$weekly_dir/"
        done
        find "$weekly_dir" -type f -name "*.sql.gz" | sort -r | tail -n +$((WEEKLY_KEEP + 1)) | xargs -r rm --
    fi
    if [[ $dom -eq 1 ]]; then
        log_message "Creating monthly snapshots..."
        for db in master service; do
            cp "$daily_dir/${db}-${today}.sql.gz" "$monthly_dir/"
        done
        find "$monthly_dir" -type f -name "*.sql.gz" | sort -r | tail -n +$((MONTHLY_KEEP + 1)) | xargs -r rm --
    fi
}

# Backup site data and certs
backup_data() {
    log_message "Backing up web and certificate data..."
    [ -d /var/www ] && tar -cf - /var/www | $compress_cmd -c > "$data_path/www-$host-$today.tgz"
    [ -d /etc/letsencrypt ] && tar -czf "$data_path/letsencrypt-$host-$today.tgz" -C / etc/letsencrypt
    find "$data_path" -type f -name "*.tgz" -mtime +$DATA_RETENTION -delete
}

# Check backup file integrity
verify_backups() {
    log_message "Verifying backup integrity..."
    local error_count=0
    for file in "$config_path"/*-$today.tgz "$data_path"/*-$today.tgz; do
        [ -f "$file" ] && ! tar -tzf "$file" >/dev/null && { log_error "Corrupted file: $file"; ((error_count++)); }
    done
    for file in "$daily_dir"/*-$today.sql.gz; do
        [ -f "$file" ] && ! gzip -t "$file" 2>/dev/null && { log_error "Corrupted SQL file: $file"; ((error_count++)); }
    done
    return $error_count
}

# Main backup workflow
main() {
    rotate_log
    log_message "Starting backup for $host"
    check_root
    install_prerequisites
    mount_nas
    backup_configs
    backup_databases
    create_snapshots
    backup_data
    if verify_backups; then
        log_message "Backup completed successfully"
        send_notification "SUCCESS" "Backup completed successfully on $host at $(date)"
    else
        log_error "Backup completed with errors"
        send_notification "WARNING" "Backup completed with errors on $host at $(date)"
        exit 1
    fi
}

main "$@"
