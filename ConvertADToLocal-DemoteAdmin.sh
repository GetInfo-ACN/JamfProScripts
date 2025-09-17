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
# Version: v1.2
#
################################################################################

Version="1.2"
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
    
    # Exit if no user or system user
    if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" ]]; then
        log "No user logged in or setup user active, exiting."
        exit 0
    fi
    
    log "Current logged in user: $currentUser"
    echo "$currentUser"
}

RemoveAD() {
    log "Removing Active Directory binding..."
    searchPath=$(/usr/bin/dscl /Search -read . CSPSearchPath | grep Active\ Directory | sed 's/^ //')
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
    
    AuthenticationAuthority=$(/usr/bin/dscl -plist . -read /Users/$username AuthenticationAuthority)
    Kerberosv5=$(echo "$AuthenticationAuthority" | xmllint --xpath 'string(//string[contains(text(),"Kerberosv5")])' -)
    LocalCachedUser=$(echo "$AuthenticationAuthority" | xmllint --xpath 'string(//string[contains(text(),"LocalCachedUser")])' -)
    
    if [[ ! -z "$Kerberosv5" ]]; then
        /usr/bin/dscl -plist . -delete /Users/$username AuthenticationAuthority "$Kerberosv5"
    fi
    
    if [[ ! -z "$LocalCachedUser" ]]; then
        /usr/bin/dscl -plist . -delete /Users/$username AuthenticationAuthority "$LocalCachedUser"
    fi
    
    shadowhash=$(/usr/bin/dscl . -read /Users/$username AuthenticationAuthority | grep " ;ShadowHash;HASHLIST:<")
    if [[ -n "$shadowhash" ]]; then
        log "Preserving password hash for $username"
        /usr/bin/dscl . -delete /Users/$username AuthenticationAuthority
        /usr/bin/dscl . -create /Users/$username AuthenticationAuthority "$shadowhash"
    fi
}

SavePermissionState() {
    local username="$1"
    local homedir="$2"
    
    log "Saving permission state for $username"
    local groups=$(id -Gn "$username" | tr ' ' '\n' | sort)
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
        /usr/sbin/chown -R "$username" "$homedir"
        log "Adding $username to the staff group"
        /usr/sbin/dseditgroup -o edit -a "$username" -t user staff
        
        if [[ -f "$backup_dir/$username.groups" ]]; then
            while read group; do
                if [[ -n "$group" && "$group" != "staff" && "$group" != "admin" ]]; then
                    log "Restoring group: $group for $username"
                    /usr/sbin/dseditgroup -o edit -a "$username" -t user "$group" 2>/dev/null
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
    
    accounttype=$(/usr/bin/dscl . -read /Users/"$username" AuthenticationAuthority | head -2 | awk -F'/' '{print $2}' | tr -d '\n')
    if [[ "$accounttype" != "Active Directory" ]]; then
        log "$username is not an AD mobile account"
        # Still demote if user is admin
        DemoteFromAdmin "$username"
        return
    fi
    
    log "$username is an AD mobile account. Converting to a local account and removing admin privileges."
    homedir=$(/usr/bin/dscl . -read /Users/"$username" NFSHomeDirectory | awk '{print $2}')
    
    SavePermissionState "$username" "$homedir"
    
    if fdesetup list | grep -q "$username"; then
        log "$username has FileVault access"
    fi
    
    log "Removing AD attributes for $username"
    /usr/bin/dscl . -delete /Users/$username cached_groups
    /usr/bin/dscl . -delete /Users/$username cached_auth_policy
    /usr/bin/dscl . -delete /Users/$username CopyTimestamp
    /usr/bin/dscl . -delete /Users/$username AltSecurityIdentities
    /usr/bin/dscl . -delete /Users/$username SMBPrimaryGroupSID
    /usr/bin/dscl . -delete /Users/$username OriginalAuthenticationAuthority
    /usr/bin/dscl . -delete /Users/$username OriginalNodeName
    /usr/bin/dscl . -delete /Users/$username SMBSID
    /usr/bin/dscl . -delete /Users/$username SMBScriptPath
    /usr/bin/dscl . -delete /Users/$username SMBPasswordLastSet
    /usr/bin/dscl . -delete /Users/$username SMBGroupRID
    /usr/bin/dscl . -delete /Users/$username PrimaryNTDomain
    /usr/bin/dscl . -delete /Users/$username AppleMetaRecordName
    /usr/bin/dscl . -delete /Users/$username MCXSettings
    /usr/bin/dscl . -delete /Users/$username MCXFlags
    
    PasswordMigration "$username"
    log "Restarting directory services"
    /usr/bin/killall opendirectoryd
    sleep 20
    
    UpdatePermissions "$username" "$homedir"
    
    # Demote user from admin after conversion
    DemoteFromAdmin "$username"
}

# Main Program
RunAsRoot "$0"

# Get current user
currentUser=$(GetCurrentUser)

if [[ "$check4AD" == "Active Directory" ]]; then
    RemoveAD
fi

ConvertAndDemoteUser "$currentUser"

log "Running Jamf recon to update inventory"
if command -v jamf &> /dev/null; then
    sudo jamf recon
else
    log "Jamf binary not found, skipping inventory update"
fi

log "Script completed successfully - $currentUser converted to local account and demoted from admin"
exit 0