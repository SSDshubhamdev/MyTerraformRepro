
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request - Pipeline 1
# This script records a request only.
# It does NOT stop or delete the VM.
# ============================================================

# STEP 1: Validate required environment variables

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
        throw "Required environment variable is missing: $variable. Check the workflow env mapping."
    }
}

# STEP 2: Read inputs

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
    throw "Requester email address is invalid."
}

$waitingPeriodDays = switch ($environment) {
    "Dev"  { 7 }
    "Prod" { 11 }
}

Write-Host "============================================"
Write-Host "Azure VM Decommission Request"
Write-Host "============================================"
Write-Host "Subscription  : $subscriptionId"
Write-Host "Resource Group: $resourceGroup"
Write-Host "VM Name       : $vmName"
Write-Host "Environment   : $environment"
Write-Host "Requester     : $requester"
Write-Host "Waiting Period: $waitingPeriodDays days"
Write-Host "============================================"

# STEP 3: Verify Azure login

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure login verification failed: $($accountJson -join "`n")"
}

# STEP 4: Select and verify subscription

az account set --subscription "$subscriptionId"

if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscriptionId'."
}

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve the active Azure subscription."
}

$account = ($accountJson -join "`n") | ConvertFrom-Json

if ($account.id -ne $subscriptionId) {
    throw "Active Azure subscription does not match SUBSCRIPTION_ID."
}

Write-Host "Azure subscription verified."

# STEP 5: Validate target VM

Write-Host "Validating Azure VM..."

$vmJson = az vm show `
    --subscription "$subscriptionId" `
    --resource-group "$resourceGroup" `
    --name "$vmName" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed. Check the subscription, resource group, VM name, and Azure permissions. Details: $($vmJson -join "`n")"
}

$vm = ($vmJson -join "`n") | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($vm.id)) {
    throw "Azure returned no VM resource ID."
}

Write-Host "VM found: $($vm.name)"
Write-Host "VM ID: $($vm.id)"

# STEP 6: Collect dependency references

$nicIds = @()

if ($vm.networkProfile -and $vm.networkProfile.networkInterfaces) {
    $nicIds = @(
        $vm.networkProfile.networkInterfaces |
            ForEach-Object { $_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

$osDiskId = ""

if ($vm.storageProfile -and $vm.storageProfile.osDisk) {
    if ($vm.storageProfile.osDisk.managedDisk) {
        $osDiskId = [string]$vm.storageProfile.osDisk.managedDisk.id
    }
}

# STEP 7: Generate request ID

$requestId = [guid]::NewGuid().ToString()
$partitionKey = "DECOMMISSION_REQUEST"
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

Write-Host "Request ID: $requestId"

# STEP 8: Insert request into Azure Storage Table

$entityArguments = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=PendingApproval"
    "RequestedAction=Decommission"
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
    "WaitingPeriodDays=$waitingPeriodDays"
    "VmStopped=false"
    "VmDeleted=false"
)

Write-Host "Saving request to Azure Storage Table..."

$insertResult = az storage entity insert `
    --account-name "$storageAccount" `
    --table-name "$tableName" `
    --auth-mode login `
    --if-exists fail `
    --entity $entityArguments `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure Storage Table insert failed. Verify that the table exists and the identity has Storage Table data permissions. Details: $($insertResult -join "`n")"
}

Write-Host "Request saved successfully."

# STEP 9: Create JSON summary

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
    waitingPeriodDays = $waitingPeriodDays
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

Write-Host "Summary created: $summaryPath"

# STEP 10: Publish request ID to GitHub Actions

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "request_id=$requestId" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

    Write-Host "Request ID published to GitHub Actions."
}
else {
    throw "GITHUB_OUTPUT is missing. This script must run inside GitHub Actions."
}

# STEP 11: Add GitHub Actions run summary

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @"
## Azure VM Decommission Request

| Field | Value |
|---|---|
| Request ID | $requestId |
| Status | PendingApproval |
| Subscription ID | $subscriptionId |
| Resource Group | $resourceGroup |
| VM Name | $($vm.name) |
| Environment | $environment |
| Requester | $requester |
| Requested At UTC | $requestedAtUtc |
| Waiting Period | $waitingPeriodDays days |
| VM Stopped | No |
| VM Deleted | No |

This pipeline records the request only. It does not stop or delete Azure resources.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# STEP 12: Final result

Write-Host "============================================"
Write-Host "REQUEST SUBMITTED SUCCESSFULLY"
Write-Host "============================================"
Write-Host "Request ID : $requestId"
Write-Host "Status     : PendingApproval"
Write-Host "VM stopped : No"
Write-Host "VM deleted : No"
Write-Host "============================================"
