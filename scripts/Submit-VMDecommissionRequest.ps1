
$ErrorActionPreference = "Stop"

# Required workflow inputs
$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$requesterEmail = $env:REQUESTER_EMAIL
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME

$required = @{
    SUBSCRIPTION_ID = $subscriptionId
    RESOURCE_GROUP  = $resourceGroup
    VM_NAME         = $vmName
    VM_ENVIRONMENT  = $environment
    REQUESTER       = $requester
    REQUESTER_EMAIL = $requesterEmail
    STORAGE_ACCOUNT = $storageAccount
    TABLE_NAME      = $tableName
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Missing required environment variable: $($item.Key)"
    }
}

Write-Host "========================================"
Write-Host " Azure VM Decommission Request"
Write-Host "========================================"

# STEP 1: Verify Azure login
Write-Host "`nSTEP 1: Verifying Azure subscription..."

$accountOutput = & az account show `
    --subscription $subscriptionId `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure subscription verification failed: $($accountOutput -join "`n")"
}

Write-Host "Azure subscription verified."

# STEP 2: Validate VM
Write-Host "`nSTEP 2: Validating VM..."

$vmOutput = & az vm show `
    --subscription $subscriptionId `
    --resource-group $resourceGroup `
    --name $vmName `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed: $($vmOutput -join "`n")"
}

$vm = ($vmOutput -join "`n") | ConvertFrom-Json

$vmId = [string]$vm.id
$location = [string]$vm.location
$osDiskId = [string]$vm.storageProfile.osDisk.managedDisk.id

$nicIds = @(
    $vm.networkProfile.networkInterfaces |
        ForEach-Object { [string]$_.id }
) -join ";"

Write-Host "VM Name: $vmName"
Write-Host "VM ID: $vmId"
Write-Host "Location: $location"

# STEP 3: Create request ID and save request before stopping
Write-Host "`nSTEP 3: Saving request in Azure Table..."

$requestId = [guid]::NewGuid().ToString()
$partitionKey = $environment
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

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

$insertArgs = @(
    "storage", "entity", "insert",
    "--account-name", $storageAccount,
    "--table-name", $tableName,
    "--auth-mode", "login",
    "--if-exists", "fail",
    "--entity"
) + $entityArgs + @("--output", "json")

$insertOutput = & az @insertArgs 2>&1
$insertExitCode = $LASTEXITCODE

if ($insertExitCode -ne 0) {
    throw "Azure Table insert failed. Check table existence and Storage Table Data Contributor permission. Details: $($insertOutput -join "`n")"
}

Write-Host "Request saved successfully."
Write-Host "Request ID: $requestId"

# STEP 4: Get current VM power state
Write-Host "`nSTEP 4: Checking VM power state..."

$stateOutput = & az vm get-instance-view `
    --subscription $subscriptionId `
    --resource-group $resourceGroup `
    --name $vmName `
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" `
    --output tsv 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve VM power state: $($stateOutput -join "`n")"
}

$powerState = ($stateOutput -join "`n").Trim()
Write-Host "Current power state: $powerState"

# STEP 5: Stop/deallocate VM if it is not already deallocated
if ($powerState -ne "PowerState/deallocated") {
    Write-Host "`nSTEP 5: Sending VM deallocate command..."
    Write-Host "The pipeline will wait for deallocation to complete."

    $stopOutput = & az vm deallocate `
        --subscription $subscriptionId `
        --resource-group $resourceGroup `
        --name $vmName `
        --output json 2>&1

    $stopExitCode = $LASTEXITCODE

    if ($stopExitCode -ne 0) {
        throw "VM deallocation command failed. Request ID: $requestId. Details: $($stopOutput -join "`n")"
    }

    Write-Host "Deallocate command completed. Verifying power state..."
}
else {
    Write-Host "VM is already deallocated."
}

# STEP 6: Poll until deallocated, max 30 minutes
Write-Host "`nSTEP 6: Waiting for VM deallocation confirmation..."

$maxAttempts = 60
$pollSeconds = 30
$deallocated = $false

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $stateOutput = & az vm get-instance-view `
        --subscription $subscriptionId `
        --resource-group $resourceGroup `
        --name $vmName `
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" `
        --output tsv 2>&1

    $stateExitCode = $LASTEXITCODE

    if ($stateExitCode -ne 0) {
        throw "Failed to check VM power state on attempt $attempt. Details: $($stateOutput -join "`n")"
    }

    $powerState = ($stateOutput -join "`n").Trim()
    Write-Host "Attempt $attempt/$maxAttempts : $powerState"

    if ($powerState -eq "PowerState/deallocated") {
        $deallocated = $true
        break
    }

    if ($attempt -lt $maxAttempts) {
        Write-Host "VM is not deallocated yet. Waiting $pollSeconds seconds..."
        Start-Sleep -Seconds $pollSeconds
    }
}

if (-not $deallocated) {
    throw "Timeout: VM did not reach PowerState/deallocated within 30 minutes. No success email will be sent. Request ID: $requestId"
}

Write-Host "SUCCESS: VM deallocation confirmed."

# STEP 7: Update Azure Table only after confirmed deallocation
Write-Host "`nSTEP 7: Updating request record..."

$stoppedAtUtc = [DateTime]::UtcNow.ToString("o")

$mergeEntityArgs = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "VmStopped=true"
    "VmStoppedAtUtc=$stoppedAtUtc"
    "VmPowerState=VM deallocated"
)

$mergeArgs = @(
    "storage", "entity", "merge",
    "--account-name", $storageAccount,
    "--table-name", $tableName,
    "--auth-mode", "login",
    "--entity"
) + $mergeEntityArgs + @("--output", "json")

$mergeOutput = & az @mergeArgs 2>&1
$mergeExitCode = $LASTEXITCODE

if ($mergeExitCode -ne 0) {
    throw "VM is deallocated, but the Table update failed. Request ID: $requestId. Details: $($mergeOutput -join "`n")"
}

Write-Host "Azure Table updated successfully."

# STEP 8: Publish GitHub Actions outputs for the email step
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "request_id=$requestId" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

    "request_status=PendingApproval" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

    "vm_stopped=true" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

    "vm_power_state=VM deallocated" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

# STEP 9: Summary
$summary = [ordered]@{
    RequestId         = $requestId
    RequestStatus     = "PendingApproval"
    SubscriptionId    = $subscriptionId
    ResourceGroup     = $resourceGroup
    VmName            = $vmName
    Environment       = $environment
    Requester         = $requester
    RequesterEmail    = $requesterEmail
    VmPowerState      = "VM deallocated"
    VmStopped         = $true
    VmDeleted         = $false
    WaitingPeriodDays = 7
    RequestedAtUtc    = $requestedAtUtc
    VmStoppedAtUtc    = $stoppedAtUtc
}

Write-Host "`n========== REQUEST SUMMARY =========="
$summary | ConvertTo-Json -Depth 5
Write-Host "======================================"
Write-Host "VM deallocated and verified successfully."
