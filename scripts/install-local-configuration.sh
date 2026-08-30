#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
SOURCE_CONFIGURATION="$PROJECT_DIRECTORY/Configuration/ServiceConfiguration.plist"
DESTINATION_DIRECTORY="$HOME/Library/Application Support/VitalsLoom"

if [[ ! -f "$SOURCE_CONFIGURATION" ]]; then
    echo "Missing Configuration/ServiceConfiguration.plist. Copy and fill the example first."
    exit 1
fi

install -d -m 700 "$DESTINATION_DIRECTORY"
chmod 600 "$SOURCE_CONFIGURATION"
install -m 600 "$SOURCE_CONFIGURATION" "$DESTINATION_DIRECTORY/ServiceConfiguration.plist"
echo "$DESTINATION_DIRECTORY/ServiceConfiguration.plist"
