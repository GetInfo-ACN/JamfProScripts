#!/bin/bash
#
# Aftermath SMB Collector
# Purpose: Collect and transfer jamf Aftermath data to SMB share
# https://github.com/jamf/aftermath
#
# Created: Feb 19, 2025
# Author: Huseyin Usta - GetInfo ACN
#
# This script finds Aftermath data in /private/tmp, creates a zip file and transfers it 
# to a specified SMB share using native macOS methods. The script handles mounting, file transfer,
# and cleanup operations automatically. Files are uploaded with ISO 8601 timestamp 
# (e.g., Aftermath_SERIAL_20250219.zip).
#
# Parameters:
# Parameter 4: SMB share URL (e.g., smb://192.168.1.10/aftermath)
# Parameter 5: SMB username (e.g., admin)
# Parameter 6: SMB password base64 encoded (e.g., UGFzc3dvcmQxMjM=)
#
# Version History:
# v1.0 - Initial Release
#      - Native macOS SMB mounting
#      - Base64 password support
#      - ISO 8601 date format
#      - Automatic cleanup
#
################################################################################
#
# Global Variables
#
################################################################################

# Error control
set -e 

# Jamf Script Parameters
SHARE_URL=$4      
SHARE_USER="$5"    
b64pass="$6"       # Base64 encoded password
SHARE_PASS="$(echo "$b64pass" | base64 -d)"  # Decode password

# Network connection check
NetworkCheck() {
    local host
    if [[ "$SHARE_URL" =~ ^smb:// ]]; then
        host=$(echo "$SHARE_URL" | sed -E 's#^smb://([^/]+).*#\1#')
        if ! /usr/bin/nc -zdw1 "$host" 445; then
            echo "ERROR: Cannot access SMB server"
            exit 1
        fi
    fi
    echo "SUCCESS: Network connection verified"
}

# Extended cleanup function
cleanup() {
    echo "Performing cleanup..."
    # Mount point cleanup
    umount "$MOUNT_POINT" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    
    # Aftermath files cleanup
    if [ "$UPLOAD_SUCCESS" = "true" ]; then
        rm -rf "$AFTERMATH_DIR"
        rm -f "$AFTERMATH_ZIP"
        echo "SUCCESS: Aftermath folder and zip files removed"
    fi
    
    echo "SUCCESS: Cleanup completed"
}

# Call cleanup at script exit
trap cleanup EXIT

# URL format check and type determination
if [[ "$SHARE_URL" =~ ^smb:// ]]; then
    SHARE_TYPE="smb"
    SHARE_PATH=${SHARE_URL#smb://}
else
    echo "ERROR: Invalid URL format (must start with smb://)"
    exit 1
fi

# Aftermath folder and zip operations
CheckAndZipFiles() {
    # Folder check
    AFTERMATH_DIR=$(find /private/tmp -type d -name "Aftermath_*" -print -quit)
    if [ -z "$AFTERMATH_DIR" ]; then
        echo "ERROR: Aftermath folder not found in /private/tmp"
        exit 1
    fi
    echo "SUCCESS: Aftermath folder found: $AFTERMATH_DIR"

    # Create zip
    cd /private/tmp
    if ! zip -r "${AFTERMATH_DIR}.zip" "$(basename "$AFTERMATH_DIR")"; then
        echo "ERROR: Failed to create zip file"
        exit 1
    fi
    echo "SUCCESS: Zip file created: ${AFTERMATH_DIR}.zip"
    
    # Assign to global variable
    AFTERMATH_ZIP="${AFTERMATH_DIR}.zip"
}

# Mount point
MOUNT_POINT="/private/tmp/.aftermath_mount"
[ -d "$MOUNT_POINT" ] && umount "$MOUNT_POINT" 2>/dev/null || true
mkdir -p "$MOUNT_POINT"

# Date format definition (ISO 8601)
DATESTAMP=$(date "+%Y%m%d")

# Main flow
UPLOAD_SUCCESS="false"
NetworkCheck        # First network check
CheckAndZipFiles   # Create zip file

if [ "$SHARE_TYPE" = "smb" ]; then
    if [ -n "$SHARE_USER" ] && [ -n "$SHARE_PASS" ]; then
        # Find current user
        Current_User=$(stat -f%Su /dev/console)
        
        # macOS native mount with osascript and credentials
        True_Path="$SHARE_URL"
        sudo -u "$Current_User" osascript -e "
            tell application \"Finder\"
                mount volume \"$True_Path\" as user name \"$SHARE_USER\" with password \"$SHARE_PASS\"
            end tell"

        # Wait for mount
        sleep 2

        # Find mount point
        MOUNT_POINT=$(mount | grep "$SHARE_PATH" | tail -1 | awk '{print $3}')
        if [ -z "$MOUNT_POINT" ]; then
            # Alternative search
            MOUNT_POINT=$(df | grep "$SHARE_PATH" | awk '{print $NF}')
        fi
        
        if [ -z "$MOUNT_POINT" ] || ! ls "$MOUNT_POINT" &>/dev/null; then
            echo "ERROR: Mount point not found or not accessible"
            exit 1
        fi
        echo "SUCCESS: SMB mounted: $MOUNT_POINT"
    else
        # Mount directly with URL if no credentials
        mount -t smbfs //${SHARE_PATH} "$MOUNT_POINT" || {
            echo "ERROR: SMB mount failed (direct URL)"
            rm -rf "$MOUNT_POINT"
            exit 1
        }
    fi
    
    if ! ls "$MOUNT_POINT" &>/dev/null; then
        echo "ERROR: Mount appears successful but directory not accessible"
        cleanup
        exit 1
    fi
    echo "SUCCESS: SMB mounted"

    # Copy operation for SMB
    if ! cp "$AFTERMATH_ZIP" "$MOUNT_POINT/$(basename ${AFTERMATH_DIR})_${DATESTAMP}.zip"; then
        echo "ERROR: Failed to copy zip file"
        exit 1
    fi
    echo "SUCCESS: Zip file copied to mount point"
else
    echo "ERROR: Invalid share type"
    rm -rf "$MOUNT_POINT"
    exit 1
fi

# Local cleanup
if ! rm -- "$AFTERMATH_ZIP"; then
    echo "ERROR: Failed to remove local zip file"
    exit 1
fi
echo "SUCCESS: Local zip file removed"

# After successful transfer
UPLOAD_SUCCESS="true"
echo "Transfer completed successfully"

# Run inventory update in background
/usr/local/bin/jamf recon &

exit 0 