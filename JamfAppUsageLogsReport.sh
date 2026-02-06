#!/bin/bash
#
# Jamf App Usage Logs Report (Client Credentials / OAuth)
# Purpose: Retrieve application usage data from Jamf Pro and generate a CSV report
#
# Created: Feb 25, 2025
# Updated: Migrated to Client Credentials (OAuth 2.0) authentication
# Author: Huseyin Usta - GetInfo ACN
#
# Description:
# This script, designed to run directly in Terminal.app (not as an MDM script), connects to Jamf Pro via its API to fetch
# application usage data for all computers within the specified date range. It generates a CSV report with details on each
# computer’s app usage, including the computer name, application name, and total usage duration. The resulting report is
# saved to the user's desktop with the filename format: App_Usage_Report_YYYY-MM-DD.csv.
#
# Required API Privileges (configured in Jamf Pro > Settings > API Roles and Clients):
# - Read Computer Inventory Collection
# - Read Computers
#
# Additional Jamf Pro configuration:
# - In Settings > Computer Inventory Collection, the "Application Usage" option must be enabled so that usage data is collected.
#
# Version History:
# v1.0 - Initial Release (Basic Auth, Classic API XML)
# v2.0 - Migrated to Client Credentials / OAuth 2.0 (no Basic Auth)
#
################################################################################
#
# Global Variables
#
# URL: Jamf Pro server URL (e.g., https://yourjamfserver.jamfcloud.com)
# CLIENT_ID: OAuth 2.0 Client ID for Jamf Pro API authentication
# CLIENT_SECRET: OAuth 2.0 Client Secret for Jamf Pro API authentication
# startDate: Start date for the app usage data (format: YYYY-MM-DD)
# endDate: End date for the app usage data (format: YYYY-MM-DD)
# outputFile: Full path where the CSV report will be saved (default: user's desktop)
# timestamp: The current timestamp used to generate the report filename
#
################################################################################

# Server connection information
URL="https://yourjamfserver.jamfcloud.com"
CLIENT_ID="your_client_id_here"
CLIENT_SECRET="your_client_secret_here"

# Date range
startDate='2018-12-01'
endDate='2025-02-25'

# Timestamp for CSV file
timestamp=$(date +"%Y-%m-%d")
outputFile="$HOME/Desktop/App_Usage_Report_${timestamp}.csv"

echo "Fetching OAuth access token..."

# Obtain OAuth token using Client Credentials (same pattern as JamfAppInventoryReportWithVersions.sh)
token_response=$(/usr/bin/curl "$URL/api/v1/oauth/token" \
  --silent \
  --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$CLIENT_ID&grant_type=client_credentials&client_secret=$CLIENT_SECRET")

bearer_token=$(echo "$token_response" | sed -n 's/.*\"access_token\":\"\([^\"]*\)\".*/\1/p')

if [[ -z "$bearer_token" ]]; then
    echo "ERROR: Failed to obtain OAuth token!"
    echo "Raw response: $token_response"
    exit 1
fi

echo "OAuth token obtained successfully."

# Create CSV header row
echo "Computer Name,Application Name,Total Hours" > "$outputFile"
echo "----------------------------------------" >> "$outputFile"

# Temporary variable to track the previous computer name
previousComputer=""

echo "Fetching computer list (all pages)..."

# Get ALL computers via Jamf Pro API v1 with pagination
computer_pairs=$(
  page=0
  page_size=200
  while :; do
    page_response=$(/usr/bin/curl "$URL/api/v1/computers-inventory?page=$page&pageSize=$page_size" \
      --silent \
      --header "Authorization: Bearer $bearer_token" \
      --header "Accept: application/json")

    # Break if empty or clearly not JSON
    if [[ -z "$page_response" ]]; then
      break
    fi

    # Extract id:name pairs from this page
    page_pairs=$(echo "$page_response" | /usr/bin/python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    if not results:
        sys.exit(0)
    for item in results:
        cid = item.get('id')
        name = item.get('general', {}).get('name', 'Unknown')
        if cid is not None:
            print(f'{cid}:{name}')
except Exception:
    pass
" 2>/dev/null)

    if [[ -z "$page_pairs" ]]; then
      break
    fi

    echo "$page_pairs"

    # Next page
    page=$((page + 1))
  done | sort -u
)

total_computers=$(echo "$computer_pairs" | grep -v '^$' | wc -l | tr -d ' ')
current_computer=0

echo "A total of $total_computers computers will be processed..."

echo "$computer_pairs" | while IFS=: read -r computerID computerName; do
    # Increment progress counter
    ((current_computer++))

    # Display progress status
    echo -ne "\rProcessing: $current_computer/$total_computers computers (%$(( (current_computer * 100) / total_computers )))"

    # Retrieve application usage data for each computer (Classic API + Bearer token)
    THExml=$(/usr/bin/curl "$URL/JSSResource/computerapplicationusage/id/$computerID/${startDate}_${endDate}" \
      --silent \
      --header "Authorization: Bearer $bearer_token" \
      --header "Accept: text/xml" \
      --request GET)

    # Skip if no data returned
    if [[ -z "$THExml" ]]; then
        continue
    fi

    # Format the API response properly
    prettyXML=$(/usr/bin/xmllint --format - <<< "$THExml")

    # Get the list of applications
    appList=$(echo "$prettyXML" | /usr/bin/awk -F '[<>]' '/<name>/{print $3}' | sort | uniq)

    # Loop through each application
    while read -r appName; do
        # Sum up the total duration for all versions of each application
        totalMinutes=$(echo "$THExml" | xmllint --format - | awk -v app="$appName" '
            /<name>/ && $0 ~ app {
                getline
                getline
                if($0 ~ /foreground/) {
                    gsub(/[^0-9]/, "", $0)
                    sum += $0
                }
            }
            END { print sum }
        ')

        # Convert duration into days/hours/minutes format
        days=$(( totalMinutes / 1440 ))
        remaining_after_days=$(( totalMinutes % 1440 ))
        hours=$(( remaining_after_days / 60 ))
        minutes=$(( remaining_after_days % 60 ))

        # Calculate total hours (days * 24 + hours)
        total_hours=$(( (days * 24) + hours ))

        # Format the time similar to Jamf format
        if [[ $days -gt 0 ]]; then
            timeFormatted="${days} Days ${hours} Hours ${minutes} Minutes"
        else
            if [[ $total_hours -gt 0 ]]; then
                timeFormatted="${hours} Hours ${minutes} Minutes"
            else
                timeFormatted="${minutes} Minutes"
            fi
        fi

        # Skip recording if total duration is less than 1 minute
        if [[ $minutes -eq 0 && $hours -eq 0 && $days -eq 0 ]]; then
            continue
        fi

        # If a new computer is encountered, write its name
        if [[ "$computerName" != "$previousComputer" ]]; then
            echo "${computerName},," >> "$outputFile"
            previousComputer="$computerName"
        fi

        # Save to CSV (indented application information and duration in the correct column)
        echo ",${appName},${timeFormatted}" >> "$outputFile"

    done <<< "$appList"
done

echo

# Invalidate token (Jamf Pro API)
/usr/bin/curl "$URL/api/v1/auth/invalidate-token" \
  --silent \
  --request POST \
  --header "Authorization: Bearer $bearer_token" > /dev/null

echo -e "\nProcess completed! Results have been saved to '$outputFile'."
echo "A total of ${total_computers} computers were processed."

exit 0

