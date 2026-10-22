
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request - Pipeline 1
# 1. Validate inputs and Azure identity
# 2. Validate selected VM
# 3. Save request in Azure Table
# 4. Immediately deallocate the VM
# 5. Verify PowerState/deallocated
# 6. Update Azure Table status
#
# IMPORTANT: VM is NOT deleted.
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
        throw "Required environment variable is missing: $variable. Check workflow env mapping."
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
Write-Host "Action        : Immediate Deallocation"
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
    throw "Unable to retrieve active Azure subscription."
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
    throw "VM validation failed: $($vmJson -join "`n")"
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

if ($vm.storageProfile -and $vm.storageProfile.osDisk -and
    $vm.storageProfile.osDisk.managedDisk) {
    $osDiskId = [string]$vm.storageProfile.osDisk.managedDisk.id
}

# STEP 7: Generate request ID and publish output early

$requestId = [guid]::NewGuid().ToString()
$partitionKey = "DECOMMISSION_REQUEST"
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")
$workspace = $env:GITHUB_WORKSPACE

if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = (Get-Location).Path
}

$summaryPath = Join-Path $workspace "decommission-request-summary.json"

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw "GITHUB_OUTPUT is missing. Run this script inside GitHub Actions."
}

"request_id=$requestId" |
    Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

Write-Host "Request ID: $requestId"

# STEP 8: Save request to Azure Storage Table BEFORE deallocation

$entityArguments = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=StopInProgress"
    "RequestedAction=Deallocate"
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
    throw "Azure Table insert failed. Check table existence and Storage Table data permissions. Details: $($insertResult -join "`n")"
}

Write-Host "Request saved successfully."

# Track the real execution result for failure handling.
$vmDeallocated = $false
$finalPowerState = "Unknown"
$operationError = $null

try {
    # STEP 9: Check current power state

    Write-Host "Checking current VM power state..."

    $instanceViewJson = az vm get-instance-view `
        --subscription "$subscriptionId" `
        --resource-group "$resourceGroup" `
        --name "$vmName" `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read VM instance view: $($instanceViewJson -join "`n")"
    }

    $instanceView = ($instanceViewJson -join "`n") | ConvertFrom-Json
    $currentPowerState = $null

    foreach ($status in $instanceView.statuses) {
        if ($status.code -like "PowerState/*") {
            $currentPowerState = $status.code
            break
        }
    }

    # STEP 10: Deallocate VM if it is not already deallocated

    if ($currentPowerState -eq "PowerState/deallocated") {
        Write-Host "VM is already deallocated."
    }
    else {
        Write-Host "Deallocating VM '$vmName'..."

        az vm deallocate `
            --subscription "$subscriptionId" `
            --resource-group "$resourceGroup" `
            --name "$vmName" `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Azure VM deallocation command failed."
        }
    }

    # STEP 11: Poll and verify final power state

    $maxAttempts = 18
    $finalPowerState = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host "Verifying power state: attempt $attempt of $maxAttempts"

        $verifyJson = az vm get-instance-view `
            --subscription "$subscriptionId" `
            --resource-group "$resourceGroup" `
            --name "$vmName" `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $verify = ($verifyJson -join "`n") | ConvertFrom-Json

            foreach ($status in $verify.statuses) {
                if ($status.code -like "PowerState/*") {
                    $finalPowerState = $status.code
                    break
                }
            }

            if ($finalPowerState -eq "PowerState/deallocated") {
                break
            }
        }

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 10
        }
    }

    if ($finalPowerState -ne "PowerState/deallocated") {
        throw "VM deallocation could not be confirmed. Last state: $finalPowerState"
    }

    $vmDeallocated = $true

    Write-Host "VM state verified: $finalPowerState"

    # STEP 12: Update request status in Azure Table

    $completedAtUtc = [DateTime]::UtcNow.ToString("o")

    $updateArguments = @(
        "PartitionKey=$partitionKey"
        "RowKey=$rowKey"
        "RequestStatus=Stopped"
        "VmStopped=true"
        "VmDeleted=false"
        "FinalPowerState=$finalPowerState"
        "CompletedAtUtc=$completedAtUtc"
    )

    az storage entity merge `
        --account-name "$storageAccount" `
        --table-name "$tableName" `
        --auth-mode login `
        --entity $updateArguments `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "VM is deallocated, but updating the Azure Table status failed."
    }

    # STEP 13: Create success summary

    $summary = [ordered]@{
        requestId         = $requestId
        requestStatus     = "Stopped"
        requestedAction   = "Deallocate"
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
        completedAtUtc    = $completedAtUtc
        finalPowerState   = $finalPowerState
        vmStopped         = $true
        vmDeleted         = $false
    }

    $summary |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $summaryPath -Encoding utf8

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        @"
## Azure VM Decommission Request

| Field | Value |
|---|---|
| Request ID | $requestId |
| Status | Stopped |
| Subscription ID | $subscriptionId |
| Resource Group | $resourceGroup |
| VM Name | $($vm.name) |
| Environment | $environment |
| Final Power State | $finalPowerState |
| VM Stopped | Yes |
| VM Deleted | No |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    Write-Host "============================================"
    Write-Host "SUCCESS: VM DEALLOCATION VERIFIED"
    Write-Host "Request ID : $requestId"
    Write-Host "Status     : Stopped"
    Write-Host "VM stopped : Yes"
    Write-Host "VM deleted : No"
    Write-Host "============================================"
}
catch {
    $operationError = $_.Exception.Message
    $failedAtUtc = [DateTime]::UtcNow.ToString("o")

    # If the VM stopped but the Table update failed, do not claim
    # that the VM stop itself failed.
    if ($vmDeallocated) {
        $failureStatus = "StoppedTableUpdateFailed"
        $stoppedValue = "true"
    }
    else {
        $failureStatus = "StopFailed"
        $stoppedValue = "false"
    }

    $failureArguments = @(
        "PartitionKey=$partitionKey"
        "RowKey=$rowKey"
        "RequestStatus=$failureStatus"
        "VmStopped=$stoppedValue"
        "VmDeleted=false"
        "FailureReason=$(($operationError -replace '[\r\n]+', ' '))"
        "FailedAtUtc=$failedAtUtc"
    )

    az storage entity merge `
        --account-name "$storageAccount" `
        --table-name "$tableName" `
        --auth-mode login `
        --entity $failureArguments `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Unable to save failure status to Azure Table."
    }

    $failureSummary = [ordered]@{
        requestId      = $requestId
        requestStatus  = $failureStatus
        subscriptionId = $subscriptionId
        resourceGroup  = $resourceGroup
        vmName         = $vmName
        environment    = $environment
        vmStopped      = $vmDeallocated
        vmDeleted      = $false
        failureReason  = $operationError
        failedAtUtc    = $failedAtUtc
    }

    $failureSummary |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $summaryPath -Encoding utf8

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        @"
## Azure VM Deallocation Operation Failed

- **Request ID:** $requestId
- **VM:** $vmName
- **Request status:** $failureStatus
- **VM deallocated:** $vmDeallocated
- **VM deleted:** No
- **Error:** $operationError
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    throw
}
