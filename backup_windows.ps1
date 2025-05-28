# PowerShell Backup Script, assuming Windows Server 2022

# === Define variables ===
$Site        = "DEN1"
$Host        = $env:COMPUTERNAME
$MountPoint  = "Z:"
$BackupRoot  = Join-Path $MountPoint $Host
$ConfigPath  = Join-Path $BackupRoot "config"
$DbPath      = Join-Path $BackupRoot "db"
$DataPath    = Join-Path $BackupRoot "data"

# === Set up logging ===
$LogDir      = "C:\ProgramData\Backup\Logs"
$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile     = Join-Path $LogDir "backup_$Timestamp.log"
$SuccessFile = Join-Path $LogDir "backup_success.txt"
$FailureFile = Join-Path $LogDir "backup_failed.txt"

# === MySQL and Email ===
$MySQLPath   = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
$EmailFrom   = "Backup Log"
$EmailTo     = "ukarang@ukarang.com"
$SmtpServer  = "smtp.gmail.com"
$SmtpPort    = 587
$AppPassword = "the-backup-app-password"

# === Init log directory and start log ===
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Remove-Item $SuccessFile, $FailureFile -ErrorAction SilentlyContinue
Add-Content $LogFile "`n===== Backup Started at $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") ====="

# === Logging functions ===
function Log {
    param ([string]$Message)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$time :: $Message" | Tee-Object -FilePath $LogFile -Append
}

function Try-Step {
    param ([string]$StepName, [scriptblock]$Action)
    try {
        Log "$StepName - START"
        & $Action
        Log "$StepName - SUCCESS"
    } catch {
        Log "$StepName - FAILED: $_"
        throw
    }
}

function Send-Email {
    param ([string]$Subject, [string]$Body)
    $securePass = ConvertTo-SecureString $AppPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($EmailFrom, $securePass)
    Send-MailMessage -From $EmailFrom -To $EmailTo -Subject $Subject -Body $Body `
        -SmtpServer $SmtpServer -Port $SmtpPort -UseSsl -Credential $cred
}

# === Install backup feature if missing ===
Try-Step "Checking Windows-Server-Backup" {
    if (-not (Get-WindowsFeature -Name Windows-Server-Backup).Installed) {
        Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools
    }
}

# === Confirm mount is available ===
if (-not (Test-Path $MountPoint)) {
    Log "Mount point $MountPoint is not available."
    New-Item -ItemType File -Path $FailureFile | Out-Null
    Send-Email "[FAILURE] Backup failed - $Host @ $Timestamp" "Mount point $MountPoint not found. Log: $LogFile"
    exit 1
}

# === Make backup folders ===
New-Item -ItemType Directory -Path $ConfigPath, "$DbPath\d", "$DbPath\w", "$DbPath\m", $DataPath -Force | Out-Null

# === Back up config files ===
Try-Step "Backing up config files" {
    Set-Location $ConfigPath
    tar.exe -zcvf etc.tgz         C:\Windows\System32\drivers\etc
    tar.exe -zcvf users.tgz       C:\Users
    tar.exe -zcvf programdata.tgz C:\ProgramData
    ipconfig /all > ipconfig.txt
    systeminfo > systeminfo.txt
    Get-CimInstance Win32_OperatingSystem | Select Caption, Version, OSArchitecture > osversion.txt
}

# === Back up MySQL databases ===
Try-Step "Backing up MySQL" {
    $date = Get-Date -Format "yyyy-MM-dd"
    Set-Location "$DbPath\d"
    & "$MySQLPath\mysqldump.exe" -h mydb1.systems.com -u master  -pmypassword --all-databases > "master_$date.sql"
    & "$MySQLPath\mysqldump.exe" -h mydb1.systems.com -u service -pmypassword service > "service_$date.sql"
    Get-ChildItem "$DbPath\d" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } | Move-Item -Destination "$DbPath\w"
    Get-ChildItem "$DbPath\w" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Move-Item -Destination "$DbPath\m"
}

# === Back up IIS web content ===
Try-Step "Backing up website" {
    Set-Location $DataPath
    tar.exe -zcvf "$Site`_inetpub_$(Get-Date -Format yyyy-MM-dd).tgz" C:\inetpub
}

# === Clean up old files ===
Try-Step "Cleaning up old backups" {
    Get-ChildItem "$DbPath\d" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item
    Get-ChildItem "$DbPath\w" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-21) } | Remove-Item
    Get-ChildItem "$DbPath\m" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } | Remove-Item
}

# === Success exit ===
Log "Backup completed successfully."
New-Item -ItemType File -Path $SuccessFile | Out-Null
Send-Email "[SUCCESS] Backup complete - $Host @ $Timestamp" "Backup completed at $Timestamp on $Host."
exit 0

# === Trap any other errors ===
trap {
    Log "Unhandled exception: $($_.Exception.Message)"
    New-Item -ItemType File -Path $FailureFile | Out-Null
    Send-Email "[FAILURE] Backup failed - $Host @ $Timestamp" "Error: $($_.Exception.Message)`nSee log: $LogFile"
    exit 1
}
