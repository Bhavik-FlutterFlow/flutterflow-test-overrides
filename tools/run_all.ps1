# This script automates the process of downloading the latest code from FlutterFlow
# and then applying local test overrides.

# Exit immediately if a command exits with a non-zero status.
$ErrorActionPreference = "Stop"

# --- Main Script ---

# Get the directory of this script, then go up one level to the project root.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir/..").Path

Set-Location $ProjectRoot

# Check for flutterflow_cli
if (-not (Get-Command -Name flutterflow -ErrorAction SilentlyContinue)) {
    Write-Error "Error: The FlutterFlow CLI is not installed."
    Write-Host "Please install it by running: dart pub global activate flutterflow_cli"
    exit 1
}

# Check for FlutterFlow API Token from file, environment variable, or prompt
$TokenFile = "$ScriptDir/.ff_token"
$FlutterFlowApiToken = $null

if (Test-Path $TokenFile) {
    $FlutterFlowApiToken = Get-Content $TokenFile
} elseif ($env:FLUTTERFLOW_API_TOKEN) {
    $FlutterFlowApiToken = $env:FLUTTERFLOW_API_TOKEN
} else {
    $secureToken = Read-Host -AsSecureString -Prompt "Please enter your FlutterFlow API Token"
    $FlutterFlowApiToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken))
}

if ([string]::IsNullOrEmpty($FlutterFlowApiToken)) {
    Write-Error "Error: No API token provided. Exiting."
    exit 1
}

Write-Host "Downloading code from FlutterFlow..."

# Download the code from FlutterFlow
flutterflow export-code `
    --project upload-image-test-case-tiahf4 `
    --endpoint https://api-enterprise-india.flutterflow.io/v2 `
    --project-environment Production `
    --include-assets `
    --no-parent-folder `
    --token "$FlutterFlowApiToken"

Write-Host "FlutterFlow code downloaded successfully."
Write-Host ""
Write-Host "Applying test overrides..."

# Ensure tool dependencies are installed
Set-Location $ScriptDir
dart pub get | Out-Null
Set-Location $ProjectRoot

# Run the override script, passing along any arguments
# Note: This passes all arguments from the ps1 script to the dart script
dart run tools/apply_ff_test_overrides.dart $args

Write-Host "All steps completed successfully."

