
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request - Pipeline 1
# Purpose:
# 1. Validate required inputs
# 2. Verify Azure subscription
# 3. Validate the target VM exists
# 4. Save request to Azure Storage Table
# 5. Generate a JSON summary
# 6. Publish Request ID to GitHub Actions
#
# IMPORTANT: This script does NOT delete the VM.
# ============================================================

# STEP 1: Validate required inputs
$requiredVariables = @(
    "SUBSCRIPTION_ID",
    "RESOURCE_GROUP",
    "VM_NAME",
    "VM_ENVIRONMENT",
    "REQUESTER",
    "REQUESTER_EMAIL",
    "STORAGE_ACCOUNT",
    "TABLE_NAME"
)

foreach ($variable in $requiredVariables) {
    $value = [Environment]::GetEnvironmentVariable($variable)

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing: $variable"
    }
}

$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$requesterEmail = $env:REQUESTER_EMAIL
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME

if ($environment -notin @("Dev", "Prod")) {
    throw "Invalid environment '$environment'. Allowed values: Dev, Prod."
}

# Basic email input validation
if ($requesterEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "Requester email address is not valid."
}

Write-Host "============================================"
Write-Host "Azure VM Decommission Request"
Write-Host "============================================"
Write-Host "Subscription : $subscriptionId"
Write-Host "Resource Group: $resourceGroup"
Write-Host "VM Name      : $vmName"
Write-Host "Environment  : $environment"
Write-Host "Requester    : $requester"
Write-Host "============================================"

# STEP 2: Verify Azure login and select subscription
az account set --subscription "$subscriptionId"

if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscriptionId'."
}

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure login verification failed: $accountJson"
}

$account = ($accountJson -join "`n") | ConvertFrom-Json

if ($account.id -ne $subscriptionId) {
    throw "The active Azure subscription does not match the requested subscription."
}

Write-Host "Azure subscription verified."

# STEP 3: Validate VM exists
Write-Host "Validating Azure VM..."

$vmJson = az vm show `
    --subscription "$subscriptionId" `
    --resource-group "$resourceGroup" `
    --name "$vmName" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed. Verify the subscription, resource group, VM name, and permissions. Details: $vmJson"
}

$vm = ($vmJson -join "`n") | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($vm.id)) {
    throw "Azure returned no VM resource ID."
}

Write-Host "VM exists: $($vm.name)"
Write-Host "VM ID: $($vm.id)"

# STEP 4: Collect basic VM dependency references
$nicIds = @()

if ($vm.networkProfile -and $vm.networkProfile.networkInterfaces) {
    $nicIds = @(
        $vm.networkProfile.networkInterfaces |
            ForEach-Object { $_.id }
    )
}

$osDiskId = $null

if ($vm.storageProfile.osDisk.managedDisk) {
    $osDiskId = $vm.storageProfile.osDisk.managedDisk.id
}

# STEP 5: Generate unique request ID
$requestId = [guid]::NewGuid().ToString()
$partitionKey = "DECOMMISSION_REQUEST"
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

Write-Host "Request ID: $requestId"

# STEP 6: Save request to Azure Storage Table
Write-Host "Saving request to Azure Storage Table..."

$entityArguments = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=PendingApproval"
    "SubscriptionId=$subscriptionId"
    "ResourceGroup=$resourceGroup"
    "VmName=$vmName"
    "VmId=$($vm.id)"
    "Environment=$environment"
    "Requester=$requester"
    "RequesterEmail=$requesterEmail"
    "Location=$($vm.location)"
    "OsDiskId=$osDiskId"
    "NicIds=$($nicIds -join ';')"
    "RequestedAtUtc=$requestedAtUtc"
    "WaitingPeriodDays=7"
)

$insertResult = az storage entity insert `
    --account-name "$storageAccount" `
    --table-name "$tableName" `
    --auth-mode login `
    --entity $entityArguments `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Failed to insert the request into Azure Storage Table. Verify table existence and Storage Table Data Contributor permissions. Details: $insertResult"
}

Write-Host "Request successfully saved to Azure Storage Table."

# STEP 7: Create JSON summary artifact
$summary = [ordered]@{
    requestId         = $requestId
    requestStatus     = "PendingApproval"
    subscriptionId    = $subscriptionId
    resourceGroup     = $resourceGroup
    vmName            = $vm.name
    vmId              = $vm.id
    environment       = $environment
    requester         = $requester
    requesterEmail    = $requesterEmail
    location          = $vm.location
    osDiskId          = $osDiskId
    nicIds            = $nicIds
    requestedAtUtc    = $requestedAtUtc
    waitingPeriodDays = 7
    vmDeleted         = $false
}

$workspace = $env:GITHUB_WORKSPACE

if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = (Get-Location).Path
}

$summaryPath = Join-Path $workspace "decommission-request-summary.json"

$summary |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Host "Request summary created: $summaryPath"

# STEP 8: Publish request ID as a GitHub Actions output
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "request_id=$requestId" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

# STEP 9: Add request information to GitHub Actions run summary
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @"
## VM Decommission Request

- **Request ID:** $requestId
- **Status:** PendingApproval
- **Subscription:** $subscriptionId
- **Resource Group:** $resourceGroup
- **VM Name:** $vmName
- **Environment:** $environment
- **Requester:** $requester
- **Requested At (UTC):** $requestedAtUtc
- **Waiting Period:** 7 days
- **VM Deleted:** No

This workflow records the request only. It does not delete Azure resources.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# STEP 10: Final result
Write-Host "============================================"
Write-Host "REQUEST SUBMITTED SUCCESSFULLY"
Write-Host "Request ID: $requestId"
Write-Host "Status: PendingApproval"
Write-Host "VM deletion: NOT PERFORMED"
Write-Host "============================================"
