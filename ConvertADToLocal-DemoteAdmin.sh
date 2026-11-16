#!/bin/bash
#
# ConvertADToLocal-DemoteAdmin.sh
# Purpose: Convert current user's AD mobile account to local account (demote admin to standard)
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Converts current user's AD mobile account to local account
#   - Preserves user passwords and essential group memberships
#   - Removes AD binding and cleans up AD attributes
#   - Admin users are demoted to standard user
#   - Maintains FileVault compatibility
#   - Logs all actions for audit trail
# Version: v1.6
# Changelog:
#   v1.6 - PasswordMigration: remove ALL Kerberosv5 entries (AD + LKDC)
#          Previously xpath 'string(...)' only matched the first entry,
#          leaving LKDC Kerberosv5 in place which caused login failure after restart.
#
################################################################################

Version="1.6"
FullScriptName=$(basename "$0")
ShowVersion="$FullScriptName $Version"
logFile="/private/var/log/mobile.to.local.log"

# Log function
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="$timestamp - $1"
    echo "$message" | tee -a "$logFile"
    logger -t "JamfConvertScript" "$message"
}

log "********* Running $ShowVersion *********"

if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root."
    exit 1
fi

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

    if /usr/sbin/dsconfigad -show 2>/dev/null | grep -q "Active Directory Domain"; then
        log "ERROR: AD binding is still present."
        return 1
    fi
    log "AD binding has been removed."
}

PasswordMigration() {
    local username="$1"
    local aa count entry i
    log "Migrating password for $username..."

    # Remove LocalCachedUser and ALL Kerberosv5 entries (AD + LKDC), keep ShadowHash/SecureToken.
    # Index-based xpath: no sed, values with spaces (/Active Directory/...) stay intact.
    aa=$(/usr/bin/dscl -plist . -read /Users/"$username" AuthenticationAuthority)
    count=$(echo "$aa" | xmllint --xpath 'count(//string)' - 2>/dev/null)
    count=${count%%.*}

    for ((i=1; i<=${count:-0}; i++)); do
        entry=$(echo "$aa" | xmllint --xpath "string((//string)[$i])" -)
        if [[ "$entry" == *LocalCachedUser* || "$entry" == *Kerberosv5* ]]; then
            log "Removing AuthenticationAuthority entry: $entry"
            /usr/bin/dscl . -delete /Users/"$username" AuthenticationAuthority "$entry"
        fi
    done

    log "Password migration complete - ShadowHash preserved in place"
}

FixPrimaryGroup() {
    local username="$1"
    local gid groupName

    # Keep the AD primary GID (no chown needed); map it to a local group nested with staff
    gid=$(/usr/bin/dscl . -read /Users/"$username" PrimaryGroupID 2>/dev/null | awk '{print $2}')
    [[ -z "$gid" ]] && return

    groupName=$(/usr/bin/dscl . -list /Groups PrimaryGroupID | awk -v g="$gid" '$2 == g {print $1; exit}')
    if [[ -z "$groupName" ]]; then
        groupName="staffAlias_${gid}"
        log "Creating local group $groupName for GID $gid"
        /usr/bin/dscl . -create /Groups/"$groupName"
        /usr/bin/dscl . -create /Groups/"$groupName" PrimaryGroupID "$gid"
        /usr/bin/dscl . -create /Groups/"$groupName" RealName "Staff Alias"
    else
        log "GID $gid already maps to local group $groupName"
    fi

    if [[ "$groupName" != "staff" ]]; then
        /usr/sbin/dseditgroup -o edit -a staff -t group "$groupName"
    fi

    log "Adding $username to the staff group"
    /usr/sbin/dseditgroup -o edit -a "$username" -t user staff
}

ConvertUser() {
    local username="$1"
    local homedir attr aa

    # AD mobile account detection
    if ! /usr/bin/dscl . -read /Users/"$username" OriginalNodeName &>/dev/null \
        && ! /usr/bin/dscl . -read /Users/"$username" SMBSID &>/dev/null; then
        log "$username is not an AD mobile account (no OriginalNodeName/SMBSID found)"
        return 1
    fi

    log "$username is an AD mobile account. Converting to a local account."
    homedir=$(/usr/bin/dscl . -read /Users/"$username" NFSHomeDirectory | awk -F': ' '{print $2}')

    if /usr/bin/fdesetup list 2>/dev/null | awk -F, '{print $1}' | grep -qx "$username"; then
        log "$username has FileVault access"
    fi

    log "Removing AD attributes for $username"
    for attr in cached_groups cached_auth_policy CopyTimestamp AltSecurityIdentities \
        SMBPrimaryGroupSID OriginalAuthenticationAuthority OriginalNodeName SMBSID \
        SMBScriptPath SMBPasswordLastSet SMBGroupRID SMBHome SMBHomeDrive PrimaryNTDomain \
        AppleMetaRecordName MCXSettings MCXFlags PasswordPolicyOptions \
        original_realname original_shell original_smb_home preserved_attributes \
        account_instance _writers_LinkedIdentity EMailAddress FirstName LastName \
        JobTitle PhoneNumber Street; do
        /usr/bin/dscl . -delete /Users/"$username" "$attr" 2>/dev/null
    done

    # Only remove Kerberos and LocalCachedUser entries, do not touch ShadowHash
    PasswordMigration "$username"

    [[ -n "$homedir" ]] && /bin/rm -f "$homedir/.account"

    log "Restarting directory services"
    /usr/bin/killall opendirectoryd

    until pgrep opendirectoryd > /dev/null; do
        sleep 1
    done
    sleep 2
    log "Directory services restarted"

    # Verify conversion before anything irreversible
    aa=$(/usr/bin/dscl . -read /Users/"$username" AuthenticationAuthority 2>/dev/null)
    if [[ "$aa" == *LocalCachedUser* || "$aa" == *Kerberosv5* ]]; then
        log "ERROR: conversion incomplete for $username, AD binding kept"
        return 1
    fi

    FixPrimaryGroup "$username"

    # Demote from admin group if member (nested AD admin membership ends with unbind)
    if /usr/sbin/dseditgroup -o checkmember -m "$username" admin &>/dev/null; then
        log "Removing $username from admin group"
        /usr/sbin/dseditgroup -o edit -d "$username" -t user admin 2>/dev/null
        log "$username demoted to standard user"
    else
        log "$username is not an admin. Nothing to demote."
    fi

    log "User and group info for $username:"
    /usr/bin/id "$username"
}

# Main Program
GetCurrentUser

# Convert user first, unbind only if conversion succeeded
ConvertUser "$currentUser" || exit 1

if /usr/bin/dscl localhost -list . | grep -qx "Active Directory"; then
    RemoveAD || exit 1
fi

log "Running Jamf recon to update inventory"
if command -v jamf &> /dev/null; then
    jamf recon
else
    log "Jamf binary not found, skipping inventory update"
fi

log "Script completed successfully - $currentUser converted to local account and demoted from admin"
exit 0
