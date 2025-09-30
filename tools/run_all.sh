#!/bin/bash

# This script automates the process of downloading the latest code from FlutterFlow
# and then applying local test overrides.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Helper Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- Main Script ---

# Get the directory of this script, then go up one level to the project root.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/.."

cd "$PROJECT_ROOT"

# Check for flutterflow_cli
if ! command_exists flutterflow; then
    echo "Error: The FlutterFlow CLI is not installed."
    echo "Please install it by running: dart pub global activate flutterflow_cli"
    exit 1
fi

# Check for FlutterFlow API Token from file, environment variable, or prompt
TOKEN_FILE="$SCRIPT_DIR/.ff_token"
if [ -f "$TOKEN_FILE" ]; then
    FLUTTERFLOW_API_TOKEN=$(cat "$TOKEN_FILE")
elif [ -z "$FLUTTERFLOW_API_TOKEN" ]; then
    read -sp "Please enter your FlutterFlow API Token: " FLUTTERFLOW_API_TOKEN
    echo
    if [ -z "$FLUTTERFLOW_API_TOKEN" ]; then
        echo "Error: No API token provided. Exiting."
        exit 1
    fi
fi

echo "Downloading code from FlutterFlow..."

# Download the code from FlutterFlow
flutterflow export-code \
    --project upload-image-test-case-tiahf4 \
    --endpoint https://api-enterprise-india.flutterflow.io/v2 \
    --project-environment Production \
    --include-assets \
    --no-parent-folder \
    --token "$FLUTTERFLOW_API_TOKEN"

echo "FlutterFlow code downloaded successfully."
echo ""
echo "Applying test overrides..."

# Ensure tool dependencies are installed
cd "$SCRIPT_DIR"
dart pub get > /dev/null
cd "$PROJECT_ROOT"

# Run the override script, passing along any arguments like --dry-run or --verbose
dart run tools/apply_ff_test_overrides.dart "$@"

echo "All steps completed successfully."
