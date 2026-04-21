#!/bin/bash
#
# ConvertADToLocal-DemoteAdmin.sh
# Purpose: Convert current user's AD mobile account to local account (preserve admin rights)
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Converts current user's AD mobile account to local account
#   - Preserves user passwords and essential group memberships
#   - Removes AD binding and cleans up AD attributes
#   - Admin users remain admins (no demotion)
#   - Maintains FileVault compatibility
#   - Logs all actions for audit trail
# Version: v1.7
# Changelog:
#   v1.7 - Removed admin demotion logic (admin rights preserved)
#          PasswordMigration updated to remove ALL Kerberosv5 entries (v1.6 logic)
#
################################################################################

Version="1.7"
FullScriptName=$(basename "$0")
ShowVersion="$FullScriptName $Version"
check4AD=$(/usr/bin/dscl localhost -list . | grep "Active Directory")
logFile="/private/var/log/mobile.to.local.log"
backup_dir="/var/root/user_backups"

OLDIFS=$IFS
IFS='.' read osvers_major osvers_minor osvers_dot_version <<< "$(/usr/bin/sw_vers -productVersion)"
IFS=$OLDIFS

log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="$timestamp - $1"
    echo "$message" | tee -a "$logFile"
    logger -t "JamfConvertScript" "$message"
}

log "********* Running $ShowVersion *********"

RunAsRoot() {
    if [[ "${USER}" != "root" ]]; then
        log "***  This application must be run as root.  Please authenticate below.  ***"
        sudo "$1" && exit 0
    fi
}

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

    LocalCachedUser=$(echo "$AuthenticationAuthority" | xmllint --xpath 'string(//string[contains(text(),"LocalCachedUser")])' -)
    if [[ -n "$LocalCachedUser" ]]; then
        log "Removing LocalCachedUser entry"
        /usr/bin/dscl -plist . -delete /Users/"$username" AuthenticationAuthority "$LocalCachedUser"
    fi

    while IFS= read -r entry; do
        if [[ -n "$entry" ]]; then
            log "Removing Kerberosv5 entry: $entry"
            /usr/bin/dscl -plist . -delete /Users/"$username" AuthenticationAuthority "$entry"
        fi
    done < <(echo "$AuthenticationAuthority" \
        | xmllint --xpath '//string[contains(text(),"Kerberosv5")]' - 2>/dev/null \
        | sed 's/<\/string>/\n/g' \
        | sed 's/<string>//g' \
        | grep -v '^$')

    log "Password migration complete - ShadowHash preserved"
}

SavePermissionState() {
    local username="$1"
    local homedir="$2"

    log "Saving permission state for $username"
    local groups
    groups=$(id -Gn "$username" | tr ' ' '\n' | sort)
    mkdir -p "$backup_dir"
    echo "$groups" > "$backup_dir/$username.groups"

    if [[ -d "$homedir" ]]; then
        log "Saving ACLs for $homedir"
        ls -le "$homedir" > "$backup_dir/$username.acls"
    fi
}

UpdatePermissions() {
    local username="$1"
    local homedir="$2"

    if [[ -n "$homedir" && -d "$homedir" ]]; then
        log "Updating home folder permissions for $username"

        local userUID
        userUID=$(/usr/bin/dscl . -read /Users/"$username" UniqueID 2>/dev/null | awk '{print $2}')
        if [[ -n "$userUID" ]]; then
            /usr/sbin/chown -R "$userUID":20 "$homedir"
            log "Home folder ownership updated with UID: $userUID"
        fi

        /usr/sbin/dseditgroup -o edit -a "$username" -t user staff

        if [[ -f "$backup_dir/$username.groups" ]]; then
            while read -r group; do
                if [[ -n "$group" \
                    && "$group" != "staff" \
                    && "$group" != *"\\"* \
                    && "$group" != "CNF:"* \
                    && "$group" != "{"*"}"* ]]; then
                    log "Restoring group: $group"
                    /usr/sbin/dseditgroup -o edit -a "$username" -t user "$group" 2>/dev/null
                fi
            done < "$backup_dir/$username.groups"
        fi

        # ensure admin (safety)
        if dseditgroup -o checkmember -m "$username" admin >/dev/null 2>&1; then
            log "$username is admin (confirmed)"
        else
            log "Re-adding $username to admin group (safety)"
            /usr/sbin/dseditgroup -o edit -a "$username" -t user admin
        fi

        /usr/bin/id "$username"
    fi
}

ConvertUser() {
    local username="$1"

    if ! /usr/bin/dscl . -read /Users/"$username" SMBSID &>/dev/null; then
        log "$username is not an AD mobile account"
        return
    fi

    log "$username is an AD mobile account. Converting..."
    homedir=$(/usr/bin/dscl . -read /Users/"$username" NFSHomeDirectory | awk '{print $2}')

    SavePermissionState "$username" "$homedir"

    /usr/bin/dscl . -delete /Users/"$username" SMBSID 2>/dev/null

    PasswordMigration "$username"

    /usr/bin/killall opendirectoryd
    sleep 2

    UpdatePermissions "$username" "$homedir"
}

RunAsRoot "$0"
GetCurrentUser
ConvertUser "$currentUser"

if [[ "$check4AD" == "Active Directory" ]]; then
    RemoveAD
fi

if command -v jamf &> /dev/null; then
    jamf recon
fi

log "Script completed successfully"
exit 0