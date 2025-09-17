#!/bin/bash
#
# AddCurrentUserToAdmin.sh
# Purpose: Add the currently logged-in user to the admin group if not already an admin
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Detects the active console user
#   - Exits if system users or no user is logged in
#   - Adds the user to the admin group if needed
#   - Logs actions to Jamf/system logs
# Version: v1.0
#
################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Get the active user
currentUser=$(stat -f%Su /dev/console)

# Exit if no user or system user
if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" ]]; then
    echo "No user logged in or setup user active, exiting."
    exit 0
fi

echo "Current logged in user: $currentUser"

# Check if the user is an admin
if dseditgroup -o checkmember -m "$currentUser" admin &>/dev/null; then
    echo "$currentUser is already an admin."
else
    echo "Adding $currentUser to admin group..."
    if dseditgroup -o edit -a "$currentUser" -t user admin; then
        echo "Successfully added $currentUser to admin group."
        # Log to Jamf/system logs
        logger -t "JamfAdminScript" "$(date): Successfully added $currentUser to admin group"
    else
        echo "Failed to add $currentUser to admin group."
        logger -t "JamfAdminScript" "$(date): Failed to add $currentUser to admin group"
        exit 1
    fi
fi