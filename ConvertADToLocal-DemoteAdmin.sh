#!/bin/bash
#
# ConvertCurrentUserADToLocal-DemoteAdmin.sh
# Purpose: Convert current AD mobile account to local account and remove admin privileges
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Converts current user's AD mobile account to local account
#   - Removes admin privileges from the user
#   - Preserves user passwords and essential group memberships
#   - Removes AD binding and cleans up AD attributes
#   - Maintains FileVault compatibility
#   - Logs all actions for audit trail
# Version: v1.5
#
################################################################################

Version="1.5"
FullScriptName=$(basename "$0")
ShowVersion="$FullScriptName $Version"
check4AD=$(/usr/bin/dscl localhost -list . | grep "Active Directory")
logFile="/private/var/log/mobile.to.local.demote.log"
backup_dir="/var/root/user_backups"

# Determine OS version
OLDIFS=$IFS
IFS='.' read osvers_major osvers_minor osvers_dot_version <<< "$(/usr/bin/sw_vers -productVersion)"
IFS=$OLDIFS

# Log function
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="$timestamp - $1"
    echo "$message" | tee -a "$logFile"
    logger -t "JamfConvertDemoteScript" "$message"
}

log "********* Running $ShowVersion *********"

RunAsRoot() {
    if [[ "${USER}" != "root" ]]; then
        log "***  This application must be run as root.  Please authenticate below.  ***"
        sudo "$1" && exit 0
    fi
}

# Get the active user
GetCurrentUser() {
    currentUser=$(stat -f%Su /dev/console)

    if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" ]]; then
        log "No user logged in or setup user active, exiting."
        exit 0
    fi

    log "Current logged in user: $currentUser"
}

RemoveAD() {
    log "Removing Active Directory binding..."
    searchPath=$(/usr/bin/dscl /Search -read . CSPSearchPath | grep "Active Directory" | sed 's/^ //')
    /usr/sbin/dsconfigad -remove -force -u none -p none
    /usr/bin/dscl /Search/Contacts -delete . CSPSearchPath "$searchPath"
    /usr/bin/dscl /Search -delete . CSPSearchPath "$searchPath"
    /usr/bin/dscl /Search -change . SearchPolicy dsAttrTypeStandard:CSPSearchPath dsAttrTypeStandard:NSPSearchPath
    /usr/bin/dscl /Search/Contacts -change . SearchPolicy dsAttrTypeStandard:CSPSearchPath dsAttrTypeStandard:NSPSearchPath
    log "AD binding has been removed."
}

PasswordMigration() {
    local username="$1"
    log "Migrating password for $username..."

    AuthenticationAuthority=$(/usr/bin/dscl -plist . -read /Users/"$username" AuthenticationAuthority)
    Kerberosv5=$(echo "$AuthenticationAuthority" | xmllint --xpath 'string(//string[contains(text(),"Kerberosv5")])' -)
    LocalCachedUser=$(echo "$AuthenticationAuthority" | xmllint --xpath 'string(//string[contains(text(),"LocalCachedUser")])' -)

    # Only remove AD-specific entries, do not touch ShadowHash
    # macOS 14+ delete/create cycle can cause silent failure
    if [[ -n "$Kerberosv5" ]]; then
        log "Removing Kerberosv5 entry"
        /usr/bin/dscl -plist . -delete /Users/"$username" AuthenticationAuthority "$Kerberosv5"
    fi

    if [[ -n "$LocalCachedUser" ]]; then
        log "Removing LocalCachedUser entry"
        /usr/bin/dscl -plist . -delete /Users/"$username" AuthenticationAuthority "$LocalCachedUser"
    fi

    log "Password migration complete - ShadowHash preserved in place"
}

SavePermissionState() {
    local username="$1"
    local homedir="$2"

    log "Saving permission state for $username"
    local groups
    groups=$(id -Gn "$username" | tr ' ' '\n' | sort)
    mkdir -p "$backup_dir"
    echo "$groups" > "$backup_dir/$username.groups"

    if dseditgroup -o checkmember -m "$username" admin > /dev/null 2>&1; then
        log "$username has admin privileges, this will be REMOVED"
        touch "$backup_dir/$username.admin.removed"
    else
        log "$username does not have admin privileges"
    fi

    if [[ -d "$homedir" ]]; then
        log "Saving ACLs for $homedir"
        ls -le "$homedir" > "$backup_dir/$username.acls"
    fi
}

DemoteFromAdmin() {
    local username="$1"

    if dseditgroup -o checkmember -m "$username" admin &>/dev/null; then
        log "$username is an admin. Removing from admin group..."
        if dseditgroup -o edit -d "$username" -t user admin; then
            log "Successfully removed $username from admin group."
        else
            log "Failed to remove $username from admin group."
            exit 1
        fi
    else
        log "$username is not an admin. Nothing to demote."
    fi
}

UpdatePermissions() {
    local username="$1"
    local homedir="$2"

    if [[ -n "$homedir" && -d "$homedir" ]]; then
        log "Updating home folder permissions for $username"

        # Use UID instead of username - opendirectoryd may not recognize username immediately after restart
        local userUID
        userUID=$(/usr/bin/dscl . -read /Users/"$username" UniqueID 2>/dev/null | awk '{print $2}')
        if [[ -n "$userUID" ]]; then
            /usr/sbin/chown -R "$userUID":20 "$homedir"
            log "Home folder ownership updated with UID: $userUID"
        else
            log "WARNING: Could not get UID for $username, skipping chown"
        fi

        log "Adding $username to the staff group"
        /usr/sbin/dseditgroup -o edit -a "$username" -t user staff

        # Restore only local groups, skip AD groups
        if [[ -f "$backup_dir/$username.groups" ]]; then
            while read -r group; do
                if [[ -n "$group" \
                    && "$group" != "staff" \
                    && "$group" != "admin" \
                    && "$group" != *"\\"* \
                    && "$group" != "CNF:"* \
                    && "$group" != "{"*"}"* ]]; then
                    log "Restoring group: $group for $username"
                    /usr/sbin/dseditgroup -o edit -a "$username" -t user "$group" 2>/dev/null
                else
                    log "Skipping AD/invalid group: $group"
                fi
            done < "$backup_dir/$username.groups"
        fi

        log "User and group info for $username:"
        /usr/bin/id "$username"
    else
        log "Home directory not found for $username"
    fi
}

ConvertAndDemoteUser() {
    local username="$1"

    # AD mobile account detection (SMBSID based - more reliable)
    if ! /usr/bin/dscl . -read /Users/"$username" SMBSID &>/dev/null; then
        log "$username is not an AD mobile account (no SMBSID found)"
        DemoteFromAdmin "$username"
        return
    fi

    log "$username is an AD mobile account. Converting to a local account and removing admin privileges."
    homedir=$(/usr/bin/dscl . -read /Users/"$username" NFSHomeDirectory | awk '{print $2}')

    SavePermissionState "$username" "$homedir"

    if /usr/bin/fdesetup list 2>/dev/null | awk -F, '{print $1}' | grep -qx "$username"; then
        log "$username has FileVault access"
    fi

    log "Removing AD attributes for $username"
    /usr/bin/dscl . -delete /Users/"$username" cached_groups 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" cached_auth_policy 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" CopyTimestamp 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" AltSecurityIdentities 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" SMBPrimaryGroupSID 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" OriginalAuthenticationAuthority 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" OriginalNodeName 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" SMBSID 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" SMBScriptPath 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" SMBPasswordLastSet 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" SMBGroupRID 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" PrimaryNTDomain 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" AppleMetaRecordName 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" MCXSettings 2>/dev/null
    /usr/bin/dscl . -delete /Users/"$username" MCXFlags 2>/dev/null

    # Only remove Kerberos and LocalCachedUser entries, do not touch ShadowHash
    PasswordMigration "$username"

    log "Restarting directory services"
    /usr/bin/killall opendirectoryd

    until pgrep opendirectoryd > /dev/null; do
        sleep 1
    done
    sleep 2
    log "Directory services restarted"

    # Change primary group from AD GID to staff (20)
    local currentGID
    currentGID=$(/usr/bin/dscl . -read /Users/"$username" PrimaryGroupID 2>/dev/null | awk '{print $2}')
    if [[ -n "$currentGID" && "$currentGID" != "20" ]]; then
        log "Changing primary group from GID $currentGID to staff (20)"
        /usr/bin/dscl . -change /Users/"$username" PrimaryGroupID "$currentGID" 20
        log "Primary group updated to staff"
    else
        log "Primary group already set to staff"
    fi

    UpdatePermissions "$username" "$homedir"
    DemoteFromAdmin "$username"
}

# Main Program
RunAsRoot "$0"

# Get current user
GetCurrentUser

# Convert and demote user first
ConvertAndDemoteUser "$currentUser"

# Remove AD binding last
if [[ "$check4AD" == "Active Directory" ]]; then
    RemoveAD
fi

log "Running Jamf recon to update inventory"
if command -v jamf &> /dev/null; then
    sudo jamf recon
else
    log "Jamf binary not found, skipping inventory update"
fi

log "Script completed successfully - $currentUser converted to local account and demoted from admin"
exit 0