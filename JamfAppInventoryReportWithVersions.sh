#!/bin/bash
#
# Jamf App Inventory Report with Versions
# Purpose: Retrieve installed applications list with versions from all computers in Jamf Pro and generate a CSV report
#
# Created: April 15, 2025
# Author: Huseyin Usta - GetInfo ACN
#
# Description:
# This script, designed to run directly in Terminal.app (not as an MDM script), connects to Jamf Pro via its API to fetch installed application data 
# for all computers. It generates a CSV report with details on each computer's installed applications, including the computer name, application name, and version. 
# Each version of an application is listed as a separate row. The resulting report is saved to the user's desktop with the filename format: 
# App_Inventory_Report_With_Versions_YYYY-MM-DD.csv.
#
# Required API Privileges (configured in Jamf Pro > Settings > API Roles and Clients):
# - Read Computer Inventory Collection
# - Read Computers
#
# Version History:
# v1.0 - Initial Release
# v2.0 - Added version column, shows each version separately
# v3.0 - Migrated to Jamf Pro API v1 with OAuth 2.0 Client Credentials authentication (replaced Basic Auth)
#
################################################################################
#
# Global Variables
#
# URL: Jamf Pro server URL (e.g., https://yourjamfserver.jamfcloud.com)
# CLIENT_ID: OAuth 2.0 Client ID for Jamf Pro API authentication
# CLIENT_SECRET: OAuth 2.0 Client Secret for Jamf Pro API authentication
# outputFile: Full path where the CSV report will be saved (default: user's desktop)
# timestamp: The current timestamp used to generate the report filename
#
################################################################################

# Server connection information
URL="https://yourjamfserver.jamfcloud.com"
CLIENT_ID="your_client_id_here"
CLIENT_SECRET="your_client_secret_here"

# Timestamp for CSV file
timestamp=$(date +"%Y-%m-%d")
outputFile="$HOME/Desktop/App_Inventory_Report_With_Versions_${timestamp}.csv"

echo "Fetching all computer IDs..."

# OAuth Token - Get Bearer Token using OAuth 2.0 Client Credentials
token_response=$(curl "$URL/api/v1/oauth/token" \
  --silent \
  --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$CLIENT_ID&grant_type=client_credentials&client_secret=$CLIENT_SECRET")

bearer_token=$(echo "$token_response" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [[ -z "$bearer_token" ]]; then
    echo "ERROR: Failed to obtain OAuth token!"
    exit 1
fi

echo "OAuth token obtained successfully"

# Create CSV header row
echo "Computer Name,Application Name,Version" > "$outputFile"

# Get only managed computers
echo "Fetching managed computer list..."
computers_list=$(curl "$URL/api/v1/computers-inventory?filter=general.remoteManagement.managed==true" \
  --silent \
  --header "Authorization: Bearer $bearer_token" \
  --header "Accept: application/json")

# Extract computer IDs - Jamf Pro API v1 JSON format: {"totalCount": X, "results": [{"id": 123, ...}, ...]}
# Parse JSON using Python (default on macOS)
computer_ids=$(echo "$computers_list" | /usr/bin/python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'results' in data:
        ids = [str(item['id']) for item in data['results'] if 'id' in item]
        print('\n'.join(ids))
except:
    pass
" 2>/dev/null | sort -u)

# Fallback if Python fails: simple regex (only first IDs in results array)
if [[ -z "$computer_ids" ]] || [[ $(echo "$computer_ids" | wc -l | tr -d ' ') -eq 0 ]]; then
    # Find results array and process only that section
    results_start=$(echo "$computers_list" | grep -n '"results"' | head -1 | cut -d: -f1)
    if [[ -n "$results_start" ]]; then
        computer_ids=$(echo "$computers_list" | sed -n "${results_start},\$p" | grep -oE '"id"\s*:\s*[0-9]+' | head -100 | grep -oE '[0-9]+$' | sort -u)
    fi
fi
actual_count=$(echo "$computers_list" | grep -o '"totalCount" : [0-9]*' | grep -o '[0-9]*')

# Check actual ID count
unique_id_count=$(echo "$computer_ids" | grep -v '^$' | wc -l | tr -d ' ')
echo "Found $actual_count managed computers, $unique_id_count unique IDs will be processed"

# Process each computer - use while read like in the original script
current=0
total_to_process=$unique_id_count
while read -r computer_id; do
    if [[ -z "$computer_id" ]]; then
        continue
    fi
    
    ((current++))
    
    # Show progress
    echo -ne "\rProcessing: $current/$total_to_process computers (%$(( (current * 100) / total_to_process )))"
    
    # Get computer details
    computer_detail=$(curl "$URL/api/v1/computers-inventory/$computer_id?section=GENERAL&section=APPLICATIONS" \
      --silent \
      --header "Authorization: Bearer $bearer_token" \
      --header "Accept: application/json")
    
    # Parse JSON using Python and output directly in CSV format - faster and more reliable
    echo "$computer_detail" | /usr/bin/python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    computer_name = data.get('general', {}).get('name', 'Unknown')
    apps = data.get('applications', [])
    
    # Filter only .app extension applications and sort
    app_list = []
    for app in apps:
        name = app.get('name', '')
        if name.endswith('.app'):
            version = app.get('version', 'Unknown')
            app_list.append((name, version))
    
    # Write in CSV format - same logic as original script
    if app_list:
        app_list.sort(key=lambda x: x[0])  # Sort by name
        first = True
        for app_name, app_version in app_list:
            if first:
                print(f'{computer_name},{app_name},{app_version}')
                first = False
            else:
                print(f',{app_name},{app_version}')
    else:
        print(f'{computer_name},No applications found,')
except Exception as e:
    pass
" 2>/dev/null >> "$outputFile"
done <<< "$computer_ids"

# Invalidate token
curl "$URL/api/v1/auth/invalidate-token" \
  --silent \
  --request POST \
  --header "Authorization: Bearer $bearer_token" > /dev/null

echo -e "\n\nProcess completed! Results have been saved to '$outputFile'"
echo "A total of $actual_count managed computers were processed."

exit 0