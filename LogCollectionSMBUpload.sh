#!/bin/bash
#
# LogCollectionSMBUpload.sh
# Purpose: Collect specified log files and transfer to SMB share
#
# Created: May 7, 2025
# Author: Updated from original by Huseyin Usta - GetInfo ACN
#
# Description:
# This script is designed to be used as a Jamf Pro MDM script. It collects specified log files from parameters 7–11,
# creates a ZIP archive, and transfers it to a specified SMB share using native macOS methods. The script handles 
# mounting, file transfer, and cleanup operations automatically.
#
# Parameters:
# Parameter 4: SMB share URL (e.g., smb://192.168.1.10/logs)
# Parameter 5: SMB username (e.g., admin)
# Parameter 6: SMB password base64 encoded (e.g., UGFzc3dvcmQxMjM=)
# Parameter 7: Log File Path 1 (e.g., /var/log/system.log)
# Parameter 8: Log File Path 2 (optional)
# Parameter 9: Log File Path 3 (optional)
# Parameter 10: Log File Path 4 (optional)
# Parameter 11: Log File Path 5 (optional)
#
################################################################################


# Initialize variables
MOUNT_POINT=""
LOG_COLLECTION_DIR=""
LOG_COLLECTION_ZIP=""
UPLOAD_SUCCESS="false"
TIMESTAMP=$(date "+%Y%m%d")

# Echo function for logging to MDM results
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_message "INFO: Script started with parameters: SHARE_URL=$4, USER=$5, LOG1=$7, LOG2=$8, LOG3=$9, LOG4=${10}, LOG5=${11}"

# Cleanup function
cleanup() {
    log_message "INFO: Performing cleanup..."
    
    # Mount point cleanup
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        if mount | grep -q "$MOUNT_POINT"; then
            log_message "INFO: Unmounting $MOUNT_POINT"
            umount "$MOUNT_POINT" 2>/dev/null || {
                log_message "WARNING: Failed to unmount $MOUNT_POINT"
            }
        fi
        
        log_message "INFO: Removing mount point directory $MOUNT_POINT"
        rm -rf "$MOUNT_POINT" 2>/dev/null || log_message "WARNING: Failed to remove mount point directory"
    else
        log_message "INFO: No mount point to clean up"
    fi
    
    # Log collection files cleanup - Always attempt cleanup regardless of upload success
    if [ -n "$LOG_COLLECTION_DIR" ] && [ -d "$LOG_COLLECTION_DIR" ]; then
        rm -rf "$LOG_COLLECTION_DIR" 2>/dev/null
        log_message "INFO: Removed log collection directory"
    fi
    
    if [ -n "$LOG_COLLECTION_ZIP" ] && [ -f "$LOG_COLLECTION_ZIP" ]; then
        rm -f "$LOG_COLLECTION_ZIP" 2>/dev/null
        log_message "INFO: Removed log collection zip file"
    fi
    
    # Additional cleanup for any leftover directories with similar names
    # Clean up any potential mount directories with the serial number and timestamp pattern
    for leftover_dir in /private/tmp/${SERIAL_NUMBER}_${TIMESTAMP}* /private/tmp/log_collection_mount_${TIMESTAMP}; do
        if [ -d "$leftover_dir" ]; then
            log_message "INFO: Cleaning up leftover directory: $leftover_dir"
            
            # Check if it's mounted
            if mount | grep -q "$leftover_dir"; then
                log_message "INFO: Unmounting leftover mount point: $leftover_dir"
                umount "$leftover_dir" 2>/dev/null || {
                    log_message "WARNING: Failed to unmount leftover mount point: $leftover_dir"
                }
            fi
            
            # Try to remove it
            rm -rf "$leftover_dir" 2>/dev/null || log_message "WARNING: Failed to remove leftover directory: $leftover_dir"
        fi
    done
    
    log_message "SUCCESS: Cleanup completed"
}

# Register cleanup function to be called at exit
trap cleanup EXIT

# Jamf Script Parameters
SHARE_URL=$4      
SHARE_USER="$5"    
b64pass="$6"

# Password decode
if [ -n "$b64pass" ]; then
    SHARE_PASS="$(echo "$b64pass" | base64 -d 2>/dev/null)" || {
        log_message "ERROR: Failed to decode base64 password"
        exit 1
    }
fi

# Log File Paths from parameters
LOG_PATH_1="$7"
LOG_PATH_2="$8"
LOG_PATH_3="$9"
LOG_PATH_4="${10}"
LOG_PATH_5="${11}"

# Get Serial Number
SERIAL_NUMBER=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
log_message "INFO: Serial Number: $SERIAL_NUMBER"

# Network connection check
NetworkCheck() {
    local host
    if [[ "$SHARE_URL" =~ ^smb:// ]]; then
        host=$(echo "$SHARE_URL" | sed -E 's#^smb://([^/]+).*#\1#')
        log_message "INFO: Checking connection to SMB server: $host"
        if ! /usr/bin/nc -zdw1 "$host" 445; then
            log_message "ERROR: Cannot access SMB server $host on port 445"
            exit 1
        fi
        log_message "SUCCESS: Network connection verified to $host"
    else
        log_message "ERROR: Invalid URL format (must start with smb://): $SHARE_URL"
        exit 1
    fi
}

# Check URL format
if [[ "$SHARE_URL" =~ ^smb:// ]]; then
    SHARE_TYPE="smb"
    SHARE_PATH=${SHARE_URL#smb://}
    log_message "INFO: SMB share path: $SHARE_PATH"
else
    log_message "ERROR: Invalid URL format (must start with smb://): $SHARE_URL"
    exit 1
fi

# Log file collection and zip operations
CollectAndZipFiles() {
    # Create directory for log collection
    LOG_COLLECTION_DIR="/private/tmp/LogCollection_${SERIAL_NUMBER}_${TIMESTAMP}"
    mkdir -p "$LOG_COLLECTION_DIR" || {
        log_message "ERROR: Failed to create directory $LOG_COLLECTION_DIR"
        exit 1
    }
    log_message "SUCCESS: Created log collection directory: $LOG_COLLECTION_DIR"
    
    # Copy log files if they exist
    log_count=0
    
    # Check and copy log file 1
    if [ -n "$LOG_PATH_1" ]; then
        if [ -f "$LOG_PATH_1" ]; then
            log_message "INFO: Copying log file 1: $LOG_PATH_1"
            cp "$LOG_PATH_1" "$LOG_COLLECTION_DIR/" && log_count=$((log_count+1))
        else
            log_message "WARNING: Log file 1 not found: $LOG_PATH_1"
        fi
    fi
    
    # Check and copy log file 2
    if [ -n "$LOG_PATH_2" ]; then
        if [ -f "$LOG_PATH_2" ]; then
            log_message "INFO: Copying log file 2: $LOG_PATH_2"
            cp "$LOG_PATH_2" "$LOG_COLLECTION_DIR/" && log_count=$((log_count+1))
        else
            log_message "WARNING: Log file 2 not found: $LOG_PATH_2"
        fi
    fi
    
    # Check and copy log file 3
    if [ -n "$LOG_PATH_3" ]; then
        if [ -f "$LOG_PATH_3" ]; then
            log_message "INFO: Copying log file 3: $LOG_PATH_3"
            cp "$LOG_PATH_3" "$LOG_COLLECTION_DIR/" && log_count=$((log_count+1))
        else
            log_message "WARNING: Log file 3 not found: $LOG_PATH_3"
        fi
    fi
    
    # Check and copy log file 4
    if [ -n "$LOG_PATH_4" ]; then
        if [ -f "$LOG_PATH_4" ]; then
            log_message "INFO: Copying log file 4: $LOG_PATH_4"
            cp "$LOG_PATH_4" "$LOG_COLLECTION_DIR/" && log_count=$((log_count+1))
        else
            log_message "WARNING: Log file 4 not found: $LOG_PATH_4"
        fi
    fi
    
    # Check and copy log file 5
    if [ -n "$LOG_PATH_5" ]; then
        if [ -f "$LOG_PATH_5" ]; then
            log_message "INFO: Copying log file 5: $LOG_PATH_5"
            cp "$LOG_PATH_5" "$LOG_COLLECTION_DIR/" && log_count=$((log_count+1))
        else
            log_message "WARNING: Log file 5 not found: $LOG_PATH_5"
        fi
    fi
    
    # Check if any logs were collected
    if [ $log_count -eq 0 ]; then
        log_message "ERROR: No log files were found at the specified paths"
        rm -rf "$LOG_COLLECTION_DIR"
        exit 1
    else
        log_message "INFO: Successfully collected $log_count log files"
    fi
    
    # Create zip
    cd /private/tmp || {
        log_message "ERROR: Failed to change directory to /private/tmp"
        exit 1
    }
    
    # List files in directory before zipping
    log_message "INFO: Files in log collection directory:"
    ls -la "$LOG_COLLECTION_DIR"
    
    # Create zip file name - Simplified naming format
    ZIP_FILENAME="${SERIAL_NUMBER}_${TIMESTAMP}.zip"
    LOG_COLLECTION_ZIP="/private/tmp/$ZIP_FILENAME"
    
    # Create zip file
    log_message "INFO: Creating zip file: $LOG_COLLECTION_ZIP"
    if ! zip -r "$ZIP_FILENAME" "$(basename "$LOG_COLLECTION_DIR")"; then
        log_message "ERROR: Failed to create zip file"
        exit 1
    fi
    
    # Verify zip file was created
    if [ ! -f "$LOG_COLLECTION_ZIP" ]; then
        log_message "ERROR: Zip file was not created"
        exit 1
    fi
    
    log_message "SUCCESS: Zip file created: $LOG_COLLECTION_ZIP ($(ls -lh "$LOG_COLLECTION_ZIP" | awk '{print $5}'))"
}

# Mount SMB share using osascript (Finder) method
MountSMBShare() {
    # Create a unique mount point with consistent naming
    MOUNT_POINT="/private/tmp/${SERIAL_NUMBER}_${TIMESTAMP}_mount"
    mkdir -p "$MOUNT_POINT" || {
        log_message "ERROR: Failed to create mount point directory"
        exit 1
    }
    log_message "INFO: Created mount point directory: $MOUNT_POINT"
    
    # Find current user
    Current_User=$(stat -f%Su /dev/console)
    log_message "INFO: Current user: $Current_User"
    
    log_message "INFO: Attempting to mount SMB share: $SHARE_URL"
    
    if [ -n "$SHARE_USER" ] && [ -n "$SHARE_PASS" ]; then
        # Use osascript (like in the successful example)
        log_message "INFO: Mounting with user credentials via Finder"
        
        if sudo -u "$Current_User" osascript -e "
            tell application \"Finder\"
                mount volume \"$SHARE_URL\" as user name \"$SHARE_USER\" with password \"$SHARE_PASS\"
            end tell"; then
            
            # Wait for mount
            sleep 2
            
            # Find mount point
            ACTUAL_MOUNT_POINT=$(mount | grep "$SHARE_PATH" | tail -1 | awk '{print $3}')
            if [ -z "$ACTUAL_MOUNT_POINT" ]; then
                # Alternative search
                ACTUAL_MOUNT_POINT=$(df | grep "$SHARE_PATH" | awk '{print $NF}')
            fi
            
            if [ -n "$ACTUAL_MOUNT_POINT" ]; then
                MOUNT_POINT="$ACTUAL_MOUNT_POINT"
                log_message "INFO: Found actual mount point: $MOUNT_POINT"
            fi
            
            # Verify access
            if ls "$MOUNT_POINT" &>/dev/null; then
                log_message "SUCCESS: SMB share mounted successfully"
                return 0
            else
                log_message "ERROR: Mount point not accessible"
                return 1
            fi
        else
            log_message "ERROR: Failed to mount SMB share with osascript"
            
            # Try alternative method as fallback
            log_message "INFO: Trying alternative mount method"
            
            # URL encode special characters in username and password
            ENCODED_USER=$(echo -n "$SHARE_USER" | perl -MURI::Escape -ne 'print uri_escape($_)')
            ENCODED_PASS=$(echo -n "$SHARE_PASS" | perl -MURI::Escape -ne 'print uri_escape($_)')
            
            SMB_MOUNT_URL="//${ENCODED_USER}:${ENCODED_PASS}@${SHARE_PATH}"
            log_message "INFO: Trying mount_smbfs with encoded credentials"
            
            if mount_smbfs -o nobrowse "$SMB_MOUNT_URL" "$MOUNT_POINT" 2>/dev/null; then
                log_message "SUCCESS: Alternative mount method successful"
                return 0
            else
                log_message "ERROR: All mount methods failed"
                return 1
            fi
        fi
    else
        # Try guest mount if no credentials
        log_message "INFO: Attempting guest mount"
        if mount_smbfs -o nobrowse "//${SHARE_PATH}" "$MOUNT_POINT" 2>/dev/null; then
            log_message "SUCCESS: SMB share mounted successfully as guest"
            return 0
        else
            log_message "ERROR: Failed to mount SMB share as guest"
            return 1
        fi
    fi
}

# Copy zip file to SMB share
CopyToSMB() {
    if [ ! -f "$LOG_COLLECTION_ZIP" ]; then
        log_message "ERROR: ZIP file does not exist: $LOG_COLLECTION_ZIP"
        return 1
    fi
    
    DEST_PATH="$MOUNT_POINT/$(basename "$LOG_COLLECTION_ZIP")"
    log_message "INFO: Copying zip file to SMB share: $DEST_PATH"
    
    if cp "$LOG_COLLECTION_ZIP" "$DEST_PATH"; then
        if [ -f "$DEST_PATH" ]; then
            log_message "SUCCESS: File successfully copied to SMB share"
            UPLOAD_SUCCESS="true"
            return 0
        else
            log_message "ERROR: File copy appeared successful but file not found on share"
            return 1
        fi
    else
        log_message "ERROR: Failed to copy file to SMB share"
        
        # Try alternative copy method
        log_message "INFO: Trying alternative copy method"
        if ditto "$LOG_COLLECTION_ZIP" "$DEST_PATH"; then
            if [ -f "$DEST_PATH" ]; then
                log_message "SUCCESS: Alternative copy method successful"
                UPLOAD_SUCCESS="true"
                return 0
            fi
        fi
        
        return 1
    fi
}

# Main flow
log_message "INFO: Starting LogCollectionSMBUpload.sh"

# Check network connectivity
NetworkCheck

# Collect and zip log files
CollectAndZipFiles

# Mount SMB share and copy file
if MountSMBShare; then
    if CopyToSMB; then
        log_message "SUCCESS: Transfer completed successfully"
    else
        log_message "ERROR: Failed to copy file to SMB share"
        exit 1
    fi
else
    log_message "ERROR: Failed to mount SMB share"
    exit 1
fi

# Run inventory update in background
log_message "INFO: Running jamf recon in background"
/usr/local/bin/jamf recon &

log_message "INFO: Script completed successfully"
exit 0