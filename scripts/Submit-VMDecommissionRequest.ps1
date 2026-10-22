
$ErrorActionPreference = "Stop"

Write-Host "======================================"
Write-Host " Azure VM Decommission Request"
Write-Host "======================================"

# Required environment variables
$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment   = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$requesterEmail = $env:REQUESTER_EMAIL
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME

$required = @{
    SUBSCRIPTION_ID  = $subscriptionId
    RESOURCE_GROUP   = $resourceGroup
    VM_NAME          = $vmName
    VM_ENVIRONMENT   = $environment
    REQUESTER        = $requester
    REQUESTER_EMAIL  = $requesterEmail
    STORAGE_ACCOUNT  = $storageAccount
    TABLE_NAME       = $tableName
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Required environment variable is missing: $($item.Key)"
    }
}

# STEP 1: Verify Azure identity and subscription
Write-Host "`nSTEP 1: Verifying Azure subscription..."

$accountJson = & az account show `
    --subscription $subscriptionId `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify Azure subscription. Details: $($accountJson -join "`n")"
}

$account = ($accountJson -join "`n") | ConvertFrom-Json
Write-Host "Subscription verified: $($account.id)"

# STEP 2: Validate the VM
Write-Host "`nSTEP 2: Validating Azure VM..."

$vmOutput = & az vm show `
    --subscription $subscriptionId `
    --resource-group $resourceGroup `
    --name $vmName `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed. Details: $($vmOutput -join "`n")"
}

$vm = ($vmOutput -join "`n") | ConvertFrom-Json

$vmId = [string]$vm.id
$location = [string]$vm.location
$osDiskId = [string]$vm.storageProfile.osDisk.managedDisk.id

$nicIds = @(
    $vm.networkProfile.networkInterfaces |
        ForEach-Object { [string]$_.id }
) -join ";"

Write-Host "VM exists: $vmName"
Write-Host "VM ID: $vmId"
Write-Host "Location: $location"

# STEP 3: Create request details
Write-Host "`nSTEP 3: Creating request..."

$requestId = [guid]::NewGuid().ToString()
$partitionKey = $environment
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

# This is a request only. No VM stop/delete is performed here.
$entityArgs = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=PendingApproval"
    "RequestedAction=Decommission"
    "SubscriptionId=$subscriptionId"
    "ResourceGroup=$resourceGroup"
    "VmName=$vmName"
    "VmId=$vmId"
    "Environment=$environment"
    "Requester=$requester"
    "RequesterEmail=$requesterEmail"
    "Location=$location"
    "OsDiskId=$osDiskId"
    "NicIds=$nicIds"
    "RequestedAtUtc=$requestedAtUtc"
    "WaitingPeriodDays=7"
    "VmStopped=false"
    "VmDeleted=false"
)

Write-Host "Request ID: $requestId"

# STEP 4: Insert entity into Azure Table
Write-Host "`nSTEP 4: Saving request to Azure Storage Table..."
Write-Host "Storage account: $storageAccount"
Write-Host "Table: $tableName"

# Build one argument list so PowerShell passes each entity field
# as a separate command-line argument to Azure CLI.
$azArgs = @(
    "storage", "entity", "insert"
    "--account-name", $storageAccount
    "--table-name", $tableName
    "--auth-mode", "login"
    "--if-exists", "fail"
    "--entity"
) + $entityArgs + @(
    "--output", "json"
)

$insertOutput = & az @azArgs 2>&1
$insertExitCode = $LASTEXITCODE

if ($insertExitCode -ne 0) {
    $details = $insertOutput -join "`n"
    throw "Azure Table insert failed. Verify that the table exists and the logged-in identity has Storage Table Data Contributor permissions. Details: $details"
}

Write-Host "Request saved successfully."

# STEP 5: Publish outputs for subsequent workflow steps
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "request_id=$requestId" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

    "request_status=PendingApproval" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

# STEP 6: Print request summary
$summary = [ordered]@{
    RequestId       = $requestId
    RequestStatus   = "PendingApproval"
    RequestedAction = "Decommission"
    SubscriptionId  = $subscriptionId
    ResourceGroup   = $resourceGroup
    VmName          = $vmName
    Environment     = $environment
    Requester       = $requester
    RequesterEmail  = $requesterEmail
    Location        = $location
    RequestedAtUtc  = $requestedAtUtc
    WaitingPeriodDays = 7
    VmStopped       = $false
    VmDeleted       = $false
}

Write-Host "`n========== REQUEST SUMMARY =========="
$summary | ConvertTo-Json -Depth 5
Write-Host "======================================"
Write-Host "Request submission completed."
