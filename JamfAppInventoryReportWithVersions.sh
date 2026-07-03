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
# v4.0 - Fixed pagination bug: computer list was silently capped at 100 (API default page-size).
#        Now loops through all pages so every managed computer is included, regardless of fleet size.
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
# NOTE: Jamf Pro API paginates results (default page-size=100), so we must loop through
# all pages to retrieve every managed computer, no matter how large the fleet is.
echo "Fetching managed computer list..."

computer_ids=""
actual_count=""
page=0
page_size=200

while :; do
    page_response=$(curl "$URL/api/v1/computers-inventory?filter=general.remoteManagement.managed==true&page=${page}&page-size=${page_size}&sort=id:asc" \
      --silent \
      --header "Authorization: Bearer $bearer_token" \
      --header "Accept: application/json")

    if [[ -z "$actual_count" ]]; then
        actual_count=$(echo "$page_response" | grep -o '"totalCount" : [0-9]*' | grep -o '[0-9]*')
    fi

    # Extract computer IDs - Jamf Pro API v1 JSON format: {"totalCount": X, "results": [{"id": 123, ...}, ...]}
    # Parse JSON using Python (default on macOS)
    page_ids=$(echo "$page_response" | /usr/bin/python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'results' in data:
        ids = [str(item['id']) for item in data['results'] if 'id' in item]
        print('\n'.join(ids))
except:
    pass
" 2>/dev/null)

    # Fallback if Python fails: simple regex (only IDs in this page's results array)
    if [[ -z "$page_ids" ]]; then
        results_start=$(echo "$page_response" | grep -n '"results"' | head -1 | cut -d: -f1)
        if [[ -n "$results_start" ]]; then
            page_ids=$(echo "$page_response" | sed -n "${results_start},\$p" | grep -oE '"id"\s*:\s*[0-9]+' | grep -oE '[0-9]+$')
        fi
    fi

    # No more results on this page -> stop paging
    if [[ -z "$page_ids" ]]; then
        break
    fi

    computer_ids="${computer_ids}${page_ids}
"

    fetched_so_far=$(echo "$computer_ids" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
    if [[ -n "$actual_count" ]] && [[ "$fetched_so_far" -ge "$actual_count" ]]; then
        break
    fi

    ((page++))
done

computer_ids=$(echo "$computer_ids" | sort -u)

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