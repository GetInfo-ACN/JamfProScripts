#!/bin/bash
#
# Jamf App Inventory Report
# Purpose: Retrieve installed applications list from all computers in Jamf Pro and generate a CSV report
#
# Created: April 15, 2025
# Author: Huseyin Usta - GetInfo ACN
#
# Description:
# This script, designed to run directly in Terminal.app (not as an MDM script), connects to Jamf Pro via its API to fetch installed application data 
# for all computers. It generates a CSV report with details on each computer's installed applications, including the computer name and application name. 
# The resulting report is saved to the user's desktop with the filename format: App_Inventory_Report_YYYY-MM-DD.csv.
#
# Version History:
# v1.0 - Initial Release
#
################################################################################
#
# Global Variables
#
# URL: Jamf Pro server URL (e.g., https://yourjamfserver.jamfcloud.com)
# userName: Jamf Pro admin username (e.g., admin)
# password: Jamf Pro admin password (e.g., your_password)
# outputFile: Full path where the CSV report will be saved (default: user's desktop)
# timestamp: The current timestamp used to generate the report filename
#
################################################################################

# Server connection information
URL="https://yourjamfserver.jamfcloud.com"
userName="adminuser"
password="adminpassword"

# Timestamp for CSV file
timestamp=$(date +"%Y-%m-%d")
outputFile="$HOME/Desktop/App_Inventory_Report_${timestamp}.csv"

# Create CSV header row
echo "Computer Name,Application Name" > "$outputFile"

# First get computer IDs
echo "Fetching all computer IDs..."
computers_response=$( /usr/bin/curl "$URL/JSSResource/computers" \
--silent \
--user "$userName:$password" \
--header "Accept: application/xml" \
--request GET )

# Extract each computer's ID number
computers_ids=$(echo "$computers_response" | grep -o '<id>[0-9]*</id>' | sed 's/<id>\([0-9]*\)<\/id>/\1/')

# Calculate number of computers
total_computers=$(echo "$computers_ids" | wc -l | tr -d ' ')
echo "Found $total_computers computers to process"

# Initialize counter
current=0

# Loop through each computer ID
while read -r computerID; do
    # Increment counter
    ((current++))
    
    # Show progress
    echo -ne "\rProcessing: $current/$total_computers computers (%$(( (current * 100) / total_computers )))"
    
    # Get computer details to retrieve the name
    computer_detail=$( /usr/bin/curl "$URL/JSSResource/computers/id/$computerID" \
    --silent \
    --user "$userName:$password" \
    --header "Accept: application/xml" \
    --request GET )
    
    # Extract computer name using a more reliable method
    computerName=$(echo "$computer_detail" | grep -o '<name>[^<]*</name>' | head -1 | sed 's/<name>\(.*\)<\/name>/\1/')
    
    # Skip if computer name is empty
    if [[ -z "$computerName" ]]; then
        echo "WARNING: No computer name found for ID $computerID, skipping."
        continue
    fi
    
    # Get software information
    app_xml=$( /usr/bin/curl "$URL/JSSResource/computers/id/$computerID/subset/software" \
    --silent \
    --user "$userName:$password" \
    --header "Accept: application/xml" \
    --request GET )
    
    # Extract only app names with .app extension
    app_list=$(echo "$app_xml" | grep -o '<name>[^<]*</name>' | sed 's/<name>\(.*\)<\/name>/\1/' | grep -E '\.app$' | sort)
    
    # Check app count
    app_count=$(echo "$app_list" | grep -v '^$' | wc -l | tr -d ' ')
    
    # Note if no apps were found
    if [[ $app_count -eq 0 ]]; then
        echo "$computerName,No applications found" >> "$outputFile"
        continue
    fi
    
    # Add computer name for first app only
    first=true
    
    # Process each application
    while IFS= read -r appName; do
        # Skip empty lines
        if [[ -z "$appName" ]]; then
            continue
        fi
        
        # Include computer name for first app, leave empty for others
        if $first; then
            echo "$computerName,$appName" >> "$outputFile"
            first=false
        else
            echo ",$appName" >> "$outputFile"
        fi
    done <<< "$app_list"
    
done <<< "$computers_ids"

echo -e "\n\nProcess completed! Results have been saved to '$outputFile'"
echo "A total of $current computers were processed."
exit 0