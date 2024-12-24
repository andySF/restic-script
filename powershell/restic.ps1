#2024-12-24

# Get the directory of the current script
$scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

# Define paths to important files
$configFilePath = Join-Path -Path $scriptDir -ChildPath "config.json"
$resticPasswordFile = Join-Path -Path $scriptDir -ChildPath "restic-password.txt"
$backupSourceFile = Join-Path -Path $scriptDir -ChildPath "sources.txt"
$excludeFile = Join-Path -Path $scriptDir -ChildPath "exclude.txt"
$logFile = Join-Path -Path $scriptDir -ChildPath "restic-backup-log.txt"
$logArchiveDir = Join-Path -Path $scriptDir -ChildPath "log_archive"
$logMaxSizeMB = 0.1  # Maximum log file size in MB before rotation

# Load configuration
if (Test-Path $configFilePath) {
    $configContent = Get-Content $configFilePath -Raw | ConvertFrom-Json
    $clientName = $configContent.clientName
    $restUrl = $configContent.restUrl
    $restUser = $configContent.restUser
    $restPassword = $configContent.restPassword
    $resticRepo = $configContent.resticRepo
    $emailSettings = $configContent.emailSettings
} else {
    throw "Configuration file not found: $configFilePath"
}

$resticRepo="rest:http://${restUser}:${restPassword}@${restUrl}/${restUser}"

# Email settings from config
$smtpServer = $emailSettings.smtpServer
$smtpFrom = $emailSettings.smtpFrom
$smtpTo = $emailSettings.smtpTo
$smtpCredential = New-Object System.Management.Automation.PSCredential(
    $emailSettings.smtpCredentialUser, 
    (ConvertTo-SecureString $emailSettings.smtpCredentialPassword -AsPlainText -Force)
)
$emailSubject = "Restic Backup Error Notification for ${clientName}"

# Function to write output to both console and log file
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedMessage = "$timestamp - $message"
    Write-Output $formattedMessage | Tee-Object -FilePath $logFile -Append
}

# Function to rotate log if it exceeds the maximum size
function Rotate-Log {
    Write-Log "Checking if log rotation is needed..."
    if (Test-Path $logFile) {
        $logSizeMB = (Get-Item $logFile).Length / 1MB
        Write-Log "Current log file size: $logSizeMB MB"
        if ($logSizeMB -gt $logMaxSizeMB) {
            if (-not (Test-Path $logArchiveDir)) {
                New-Item -ItemType Directory -Path $logArchiveDir
            }
            $timestamp = Get-Date -Format "yyyyMMddHHmmss"
            $archivedLogFile = Join-Path -Path $logArchiveDir -ChildPath "restic-backup-log-$timestamp.txt"
            Move-Item -Path $logFile -Destination $archivedLogFile
            Write-Log "Log file rotated: $archivedLogFile"
            return $archivedLogFile
        } else {
            Write-Log "Log rotation not needed."
        }
    } else {
        Write-Log "Log file does not exist, no rotation needed."
    }
    return $null
}

# Function to execute a command and capture its output and exit code
function Execute-Command {
    param (
        [string]$filePath,
        [string[]]$arguments
    )
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $filePath
    $process.StartInfo.Arguments = [string]::Join(' ', $arguments)
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.Start()

    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()

    $process.WaitForExit()
    $exitCode = $process.ExitCode

    # Output and error output for debugging purposes
    Write-Log "Output: $output"
    Write-Log "Error: $errorOutput"
    Write-Log "Exit Code: $exitCode"

    return $output, $errorOutput, $exitCode
}

# Function to parse exit code from output
function Parse-ExitCode {
    param (
        [string]$output
    )
    $exitCodePattern = "Exit Code: (\d+)"
    if ($output -match $exitCodePattern) {
        return [int]$matches[1]
    } else {
        return 0  # Return OK if not found
    }
}

# Function to run Restic backup
function Run-ResticBackup {
    Write-Log "Starting Restic backup at $(Get-Date)..."
    Write-Log "Excluding file: $excludeFile"

    # Read backup sources from file
    if (Test-Path $backupSourceFile) {
        $backupSources = Get-Content $backupSourceFile
        foreach ($source in $backupSources) {
            if ($source.Trim()) {
                Write-Log "Backing up source: $source"
                $output, $errorOutput, $exitCode = Execute-Command -filePath "restic" -arguments @("backup", $source, "--repo=$resticRepo", "--password-file=$resticPasswordFile", "--iexclude-file=$excludeFile","--skip-if-unchanged","--use-fs-snapshot")
                $parsedExitCode = Parse-ExitCode $exitCode
                if ($parsedExitCode -ne 0) {
                    throw "Restic backup failed for source: $source with exit code $parsedExitCode"
                }
            }
        }
    } else {
        Write-Log "Backup source file not found: $backupSourceFile"
        throw "Backup source file not found: $backupSourceFile"
    }

    Write-Log "Restic backup completed at $(Get-Date)."

    Write-Log "Running Restic forget and prune at $(Get-Date)..."
    # Forget old snapshots based on retention policy
    $output, $errorOutput, $exitCode = Execute-Command -filePath "restic" -arguments @("forget", "--repo=$resticRepo", "--password-file=$resticPasswordFile", "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "12", $verboseFlag)
    $parsedExitCode = Parse-ExitCode $exitCode
    if ($parsedExitCode -ne 0) {
        throw "Restic forget command failed with exit code $parsedExitCode"
    }
    
    # Prune repository to free up space
    $output, $errorOutput, $exitCode = Execute-Command -filePath "restic" -arguments @("prune", "--repo=$resticRepo", "--password-file=$resticPasswordFile", $verboseFlag)
    $parsedExitCode = Parse-ExitCode $exitCode
    if ($parsedExitCode -ne 0) {
        throw "Restic prune command failed with exit code $parsedExitCode"
    }
    
    Write-Log "Restic forget and prune completed at $(Get-Date)."
}

# Function to zip a file
function Zip-File {
    param (
        [string]$filePath,
        [string]$zipPath
    )
    if (Test-Path $filePath) {
        Compress-Archive -Path $filePath -DestinationPath $zipPath -Force
        Write-Log "Zipped log file: $zipPath"
    } else {
        Write-Log "Log file not found: $filePath"
    }
}

# Function to send an email notification with attachment
# Function to send an email notification with attachment
function Send-EmailNotification {
    param (
        [string]$subject,
        [string]$body,
        [string]$attachmentPath
    )
    try {
        $message = New-Object System.Net.Mail.MailMessage
        $message.From = $smtpFrom
        $message.To.Add($smtpTo)
        $message.Subject = $subject
        $message.Body = $body

        if (-not [string]::IsNullOrEmpty($attachmentPath) -and (Test-Path $attachmentPath)) {
            Write-Log "Attaching file: $attachmentPath"
            $attachment = New-Object System.Net.Mail.Attachment($attachmentPath)
            $message.Attachments.Add($attachment)
        } else {
            Write-Log "No attachment found or attachment path is empty."
        }

        $smtp = New-Object Net.Mail.SmtpClient($smtpServer)
        $smtp.Credentials = $smtpCredential
        $smtp.Send($message)
        Write-Log "Email notification sent successfully."
    }
    catch {
        Write-Log "Failed to send email notification: $_"
    }
    finally {
        # Ensure the file handle is closed and attempt to delete the zip file
        if (Test-Path $attachmentPath) {
            $maxRetries = 3
            $retryCount = 0
            $deleted = $false

            while (-Not $deleted -and $retryCount -lt $maxRetries) {
                try {
                    Start-Sleep -Seconds 2  # Brief pause to ensure the file handle is released
                    Remove-Item -Path $attachmentPath -Force
                    Write-Log "Attachment file deleted: $attachmentPath"
                    $deleted = $true
                }
                catch {
                    $retryCount++
                    Write-Log "Failed to delete the attachment file (attempt $retryCount): $_"
                    Start-Sleep -Seconds 2  # Wait before retrying
                }
            }

            if (-Not $deleted) {
                Write-Log "Failed to delete the attachment file after $maxRetries attempts: $attachmentPath"
            }
        }
    }
}


# Main script execution
try {
    Write-Log "############################################################################"
    Rotate-Log  # Rotate log at the start of the script
    Run-ResticBackup
}
catch {
    $errorMessage = $_
    $zipPath = Join-Path -Path $scriptDir -ChildPath "restic-backup-log.zip"
    # Close log file stream before zipping
    [System.IO.File]::OpenWrite($logFile).Close()
    Zip-File -filePath $logFile -zipPath $zipPath
    Write-Log "An error occurred: $errorMessage"
    Send-EmailNotification -subject "$emailSubject" -body "An error occurred during the Restic backup for ${clientName}: $errorMessage" -attachmentPath $zipPath
}
finally {
}