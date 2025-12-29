#!/bin/bash
#
# Jamf App Usage Logs Report
# Purpose: Retrieve application usage data from Jamf Pro and generate a CSV report
#
# Created: Feb 25, 2025
# Author: Huseyin Usta - GetInfo ACN
#
# Description:
# This script, designed to run directly in Terminal.app (not as an MDM script), connects to Jamf Pro via its API to fetch application usage data 
# for all computers within the specified date range. It generates a CSV report with details on each computer’s app usage, 
# including the computer name, application name, and total usage duration. The resulting report is saved to the user's desktop 
# with the filename format: App_Usage_Report_YYYY-MM-DD.csv.
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
# startDate: Start date for the app usage data (format: YYYY-MM-DD)
# endDate: End date for the app usage data (format: YYYY-MM-DD)
# outputFile: Full path where the CSV report will be saved (default: user's desktop)
# timestamp: The current timestamp used to generate the report filename
#
################################################################################

 
# Server connection information
URL="https://yourjamfserver.jamfcloud.com"
userName='adminuser'
password='adminpassword'

# Date range
startDate="2018-12-01"
endDate="2025-02-25"

# Timestamp for CSV file
timestamp=$(date +"%Y-%m-%d")
outputFile="$HOME/Desktop/App_Usage_Report_${timestamp}.csv"

# Create CSV header row
echo "Computer Name,Application Name,Total Hours" > "$outputFile"
echo "----------------------------------------" >> "$outputFile"

# Temporary variable to track the previous computer name
previousComputer=""

# Retrieve the list of all computers
echo "Fetching computer list..."
computers_xml=$( /usr/bin/curl "$URL/JSSResource/computers" \
--silent \
--user "$userName:$password" \
--header "Accept: text/xml" \
--request GET )

# Get the total number of computers
total_computers=$(echo "$computers_xml" | xmllint --format - | grep -c "<computer>")
current_computer=0

echo "A total of $total_computers computers will be processed..."

# Extract and process computer IDs and names
echo "$computers_xml" | xmllint --format - | awk -F'[<>]' '
    /<id>/{id=$3}
    /<name>/{
        name=$3
        print id ":" name
    }
' | sort | while IFS=: read -r computerID computerName; do
    # Increment progress counter
    ((current_computer++))
    
    # Display progress status
    echo -ne "\rProcessing: $current_computer/$total_computers computers (%$(( (current_computer * 100) / total_computers )))"
    
    # Retrieve application usage data for each computer
    THExml=$( /usr/bin/curl "$URL/JSSResource/computerapplicationusage/id/$computerID/${startDate}_${endDate}" \
    --silent \
    --user "$userName:$password" \
    --header "Accept: text/xml" \
    --request GET )

    # Format the API response properly
    prettyXML=$( /usr/bin/xmllint --format - <<< "$THExml" )

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

echo -e "\n\nProcess completed! Results have been saved to '$outputFile'."
echo "A total of ${total_computers} computers were processed."

exit 0