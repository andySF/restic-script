#!/usr/bin/env bash

# Function to send an email using sendmail
send_email() {
    subject="$1"
    body="$2"

    # Create the email headers
    {
        echo "Subject: $subject"
        echo "From: $SMTP_FROM"
        echo "To: $SMTP_TO"
        echo ""
        echo "$body"
    } | sendmail -t
}

# Get the directory of the current script
scriptDir=$(dirname "$(readlink -f "$0")")

# Define paths to important files
configFilePath="$scriptDir/config.conf"
resticPasswordFile="$scriptDir/restic-password.txt"
backupSourceFile="$scriptDir/sources.txt"
excludeFile="$scriptDir/exclude.txt"
logFile="$scriptDir/restic-backup-log.txt"
logArchiveDir="$scriptDir/log_archive"

# Load configuration
if [ -f "$configFilePath" ]; then
    source "$configFilePath"
else
    echo "ERROR: Configuration file not found!" | tee -a "$logFile"
    exit 1
fi

# Load Restic password
if [ -f "$resticPasswordFile" ]; then
    export RESTIC_PASSWORD=$(cat "$resticPasswordFile")
else
    echo "ERROR: Restic password file not found!" | tee -a "$logFile"
    send_email "ERROR: Restic Backup Failed" "Restic password file not found. The backup process could not be started."
    exit 1
fi

# Rotate log file if it exceeds the maximum size
logSizeMB=$(du -m "$logFile" | cut -f1)
if [ "$logSizeMB" -ge "$LOG_MAX_SIZE_MB" ]; then
    mkdir -p "$logArchiveDir"
    mv "$logFile" "$logArchiveDir/restic-backup-log-$(date '+%Y-%m-%d_%H-%M-%S').txt"
fi

# Initialize the Restic command with the repository, user, and password
resticCommand="restic -r rest:http://$REST_USER:$REST_PASSWORD@$REST_URL/$REST_USER backup -v"

# Include sources from sources.txt
if [ -f "$backupSourceFile" ]; then
    while IFS= read -r source; do
        # Only append non-empty lines
        if [ -n "$source" ]; then
            resticCommand="$resticCommand \"$source\""
        fi
    done < "$backupSourceFile"
else
    echo "ERROR: Sources file not found!" | tee -a "$logFile"
    send_email "ERROR: Restic Backup Failed" "Sources file not found. The backup process could not be started."
    exit 1
fi

# Add the exclude file if it exists
if [ -f "$excludeFile" ]; then
    resticCommand="$resticCommand --exclude-file=$excludeFile"
fi

# Log the full Restic command that will be executed
echo "INFO: Full Restic command: $resticCommand" | tee -a "$logFile"

# Run the Restic backup command in verbose mode and log output
eval $resticCommand >> "$logFile" 2>&1

# Check the status of the backup command
if [ $? -ne 0 ]; then
    echo "ERROR: Restic backup failed!" | tee -a "$logFile"
    send_email "ERROR: Restic Backup Failed" "The Restic backup process encountered an error. Please check the log file for details."
else
    echo "INFO: Restic backup completed successfully." | tee -a "$logFile"
    send_email "INFO: Restic Backup Completed" "The Restic backup process completed successfully. Please check the log file for details."
fi

# Unset the RESTIC_PASSWORD environment variable
unset RESTIC_PASSWORD
