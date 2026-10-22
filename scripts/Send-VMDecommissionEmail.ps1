
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request - Pipeline 1
# Purpose:
# 1. Validate required inputs
# 2. Verify Azure subscription
# 3. Validate target VM
# 4. Save request in Azure Storage Table
# 5. Generate JSON summary
# 6. Publish Request ID to GitHub Actions
#
# IMPORTANT:
# This script does NOT stop or delete the VM.
# Request remains PendingApproval.
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

$subscriptionId = $env:SUBSCRIPTION_ID.Trim()
$resourceGroup  = $env:RESOURCE_GROUP.Trim()
$vmName         = $env:VM_NAME.Trim()
$environment    = $env:VM_ENVIRONMENT.Trim()
$requester      = $env:REQUESTER.Trim()
$requesterEmail = $env:REQUESTER_EMAIL.Trim()
$storageAccount = $env:STORAGE_ACCOUNT.Trim()
$tableName      = $env:TABLE_NAME.Trim()

if ($environment -notin @("Dev", "Prod")) {
    throw "Invalid environment '$environment'. Allowed values: Dev, Prod."
}

if ($requesterEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "Requester email address is not valid."
}

Write-Host "============================================"
Write-Host " Azure VM Decommission Request"
Write-Host "============================================"
Write-Host "Subscription  : $subscriptionId"
Write-Host "Resource Group: $resourceGroup"
Write-Host "VM Name       : $vmName"
Write-Host "Environment   : $environment"
Write-Host "Requester     : $requester"
Write-Host "============================================"

# STEP 2: Verify Azure login and subscription

Write-Host "Verifying Azure subscription..."

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure login verification failed. Details: $($accountJson -join "`n")"
}

$account = ($accountJson -join "`n") | ConvertFrom-Json

az account set --subscription $subscriptionId

if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscriptionId'."
}

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify the active Azure subscription."
}

$account = ($accountJson -join "`n") | ConvertFrom-Json

if ($account.id -ne $subscriptionId) {
    throw "The active Azure subscription does not match the requested subscription."
}

Write-Host "Azure subscription verified successfully."

# STEP 3: Validate target VM

Write-Host "Validating Azure VM..."

$vmJson = az vm show `
    --subscription $subscriptionId `
    --resource-group $resourceGroup `
    --name $vmName `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed. Check subscription, resource group, VM name, and permissions. Details: $($vmJson -join "`n")"
}

$vm = ($vmJson -join "`n") | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($vm.id)) {
    throw "Azure returned no VM resource ID."
}

Write-Host "VM exists: $($vm.name)"
Write-Host "VM ID: $($vm.id)"
Write-Host "Location: $($vm.location)"

# STEP 4: Collect dependency references

$nicIds = @()

if ($vm.networkProfile -and $vm.networkProfile.networkInterfaces) {
    $nicIds = @(
        $vm.networkProfile.networkInterfaces |
            ForEach-Object { $_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

$osDiskId = $null

if ($vm.storageProfile -and $vm.storageProfile.osDisk) {
    if ($vm.storageProfile.osDisk.managedDisk) {
        $osDiskId = $vm.storageProfile.osDisk.managedDisk.id
    }
}

# STEP 5: Generate unique request ID

$requestId = [guid]::NewGuid().ToString()
$partitionKey = "DECOMMISSION_REQUEST"
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

Write-Host "Request ID: $requestId"

# STEP 6: Build Azure Table entity
# JSON format avoids problems with spaces and special characters.

$entity = @{
    PartitionKey      = $partitionKey
    RowKey            = $rowKey
    RequestId         = $requestId
    RequestStatus     = "PendingApproval"
    RequestedAction   = "Decommission"
    SubscriptionId    = $subscriptionId
    ResourceGroup     = $resourceGroup
    VmName            = $vmName
    VmId              = $vm.id
    Environment       = $environment
    Requester         = $requester
    RequesterEmail    = $requesterEmail
    Location          = $vm.location
    OsDiskId          = [string]$osDiskId
    NicIds            = ($nicIds -join ";")
    RequestedAtUtc    = $requestedAtUtc
    WaitingPeriodDays = 7
    VmDeleted         = $false
}

$entityJson = $entity | ConvertTo-Json -Depth 10 -Compress

Write-Host "Saving request to Azure Storage Table..."

$insertResult = az storage entity insert `
    --account-name $storageAccount `
    --table-name $tableName `
    --auth-mode login `
    --if-exists fail `
    --entity $entityJson `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Failed to insert the request into Azure Storage Table. Verify the table exists and the identity has Storage Table data permissions. Details: $($insertResult -join "`n")"
}

Write-Host "Request saved successfully."

# STEP 7: Create JSON summary

$summary = [ordered]@{
    requestId         = $requestId
    requestStatus     = "PendingApproval"
    requestedAction   = "Decommission"
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
    vmStopped         = $false
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

Write-Host "JSON summary created: $summaryPath"

# STEP 8: Publish Request ID to GitHub Actions

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "request_id=$requestId" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

    Write-Host "Request ID published to GitHub Actions output."
}
else {
    Write-Warning "GITHUB_OUTPUT is unavailable. Request ID was not published as a workflow output."
}

# STEP 9: Add GitHub Actions run summary

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @"
## Azure VM Decommission Request

| Field | Value |
|---|---|
| Request ID | $requestId |
| Status | PendingApproval |
| Subscription | $subscriptionId |
| Resource Group | $resourceGroup |
| VM Name | $($vm.name) |
| Environment | $environment |
| Requester | $requester |
| Requested At (UTC) | $requestedAtUtc |
| Waiting Period | 7 days |
| VM Stopped | No |
| VM Deleted | No |

**Important:** This workflow only records the decommission request.
It does not stop or delete the VM or its associated resources.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# STEP 10: Final result

Write-Host "============================================"
Write-Host " REQUEST SUBMITTED SUCCESSFULLY"
Write-Host "============================================"
Write-Host "Request ID : $requestId"
Write-Host "Status     : PendingApproval"
Write-Host "VM stopped : No"
Write-Host "VM deleted : No"
Write-Host "Waiting    : 7 days"
Write-Host "============================================"
