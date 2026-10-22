
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request - Pipeline 1
# Save request -> Deallocate VM -> Verify -> Update Azure Table
#
# OIDC authentication is handled by azure/login@v2 in workflow.
# VM is NOT deleted.
# Email is triggered by the workflow only after this script
# succeeds and publishes vm_stopped=true.
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

# STEP 2: Read and validate inputs

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

$waitingPeriodDays = if ($environment -eq "Prod") { 11 } else { 7 }

$workspace = $env:GITHUB_WORKSPACE
if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = (Get-Location).Path
}

$summaryPath = Join-Path $workspace "decommission-request-summary.json"

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw "GITHUB_OUTPUT is missing. Run this script inside GitHub Actions."
}

Write-Host "=================================================="
Write-Host "Azure VM Decommission Request"
Write-Host "=================================================="
Write-Host "Subscription  : $subscriptionId"
Write-Host "Resource Group: $resourceGroup"
Write-Host "VM Name       : $vmName"
Write-Host "Environment   : $environment"
Write-Host "Requester     : $requester"
Write-Host "Action        : Immediate Deallocation"
Write-Host "=================================================="

# STEP 3: Verify Azure login and select subscription

$accountJson = az account show --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure login verification failed: $($accountJson -join "`n")"
}

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

Write-Host "Azure OIDC identity and subscription verified."

# STEP 4: Define a function to read VM power state.
# Returns a state string or an empty string if Azure cannot
# return a readable state. Errors are logged by the caller.

function Get-AzureVmPowerState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subscription,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VirtualMachineName
    )

    # First attempt: Instance View PowerState code
    $stateOutput = az vm get-instance-view `
        --subscription "$Subscription" `
        --resource-group "$ResourceGroupName" `
        --name "$VirtualMachineName" `
        --query "statuses[?starts_with(code, 'PowerState/')].code | [0]" `
        --output tsv 2>&1

    if ($LASTEXITCODE -eq 0) {
        $state = ($stateOutput -join "`n").Trim()

        if (-not [string]::IsNullOrWhiteSpace($state) -and
            $state -ne "None") {
            return $state
        }
    }

    # Fallback: VM details powerState
    $detailsOutput = az vm show `
        --subscription "$Subscription" `
        --resource-group "$ResourceGroupName" `
        --name "$VirtualMachineName" `
        --show-details `
        --query powerState `
        --output tsv 2>&1

    if ($LASTEXITCODE -eq 0) {
        $state = ($detailsOutput -join "`n").Trim()

        if (-not [string]::IsNullOrWhiteSpace($state) -and
            $state -ne "None") {
            return $state
        }
    }

    return ""
}

# STEP 5: Validate selected VM

Write-Host "Validating Azure VM..."

$vmJson = az vm show `
    --subscription "$subscriptionId" `
    --resource-group "$resourceGroup" `
    --name "$vmName" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "VM validation failed. Check VM name, resource group, subscription and permissions. Details: $($vmJson -join "`n")"
}

$vm = ($vmJson -join "`n") | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($vm.id)) {
    throw "Azure returned no VM resource ID."
}

Write-Host "VM found: $($vm.name)"
Write-Host "VM ID: $($vm.id)"
Write-Host "Location: $($vm.location)"

# STEP 6: Collect NIC and OS disk references

$nicIds = @()

if ($vm.networkProfile -and $vm.networkProfile.networkInterfaces) {
    $nicIds = @(
        $vm.networkProfile.networkInterfaces |
            ForEach-Object { $_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

$osDiskId = ""

if ($vm.storageProfile -and
    $vm.storageProfile.osDisk -and
    $vm.storageProfile.osDisk.managedDisk) {
    $osDiskId = [string]$vm.storageProfile.osDisk.managedDisk.id
}

# STEP 7: Generate request ID and publish request_id output

$requestId = [guid]::NewGuid().ToString()
$partitionKey = "DECOMMISSION_REQUEST"
$rowKey = $requestId
$requestedAtUtc = [DateTime]::UtcNow.ToString("o")

"request_id=$requestId" |
    Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

Write-Host "Request ID: $requestId"

# Do not publish vm_stopped=true here.
# It will only be published after verification and Table update.

# STEP 8: Insert request into Azure Storage Table

$insertArguments = @(
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
    --entity $insertArguments `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Azure Table insert failed. Check table existence and Storage Table data permissions. Details: $($insertResult -join "`n")"
}

$requestSaved = $true

Write-Host "Request saved successfully."

# STEP 9: Deallocate, verify, and update status

$vmDeallocated = $false
$finalPowerState = ""
$failureStatus = "StopFailed"

try {
    Write-Host "Checking current VM power state..."

    $currentPowerState = Get-AzureVmPowerState `
        -Subscription $subscriptionId `
        -ResourceGroupName $resourceGroup `
        -VirtualMachineName $vmName

    if ([string]::IsNullOrWhiteSpace($currentPowerState)) {
        Write-Warning "Initial power state could not be read. Continuing with the deallocation command."
    }
    else {
        Write-Host "Current power state: $currentPowerState"
    }

    # STEP 10: Deallocate only if not already deallocated

    if ($currentPowerState -match '(?i)deallocated') {
        Write-Host "VM is already deallocated."
    }
    else {
        Write-Host "Sending Azure VM deallocation command..."

        az vm deallocate `
            --subscription "$subscriptionId" `
            --resource-group "$resourceGroup" `
            --name "$vmName" `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Azure VM deallocation command failed. Check Azure Activity Log and VM permissions."
        }

        Write-Host "Deallocation command accepted. Waiting for Azure to confirm the state..."
    }

    # STEP 11: Retry verification up to 60 times, 10 seconds apart.

    $maxAttempts = 60
    $retrySeconds = 10
    $finalPowerState = ""

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host "Verifying VM power state: attempt $attempt of $maxAttempts"

        $reportedState = Get-AzureVmPowerState `
            -Subscription $subscriptionId `
            -ResourceGroupName $resourceGroup `
            -VirtualMachineName $vmName

        if (-not [string]::IsNullOrWhiteSpace($reportedState)) {
            $finalPowerState = $reportedState
            Write-Host "Azure reported power state: $finalPowerState"

            if ($finalPowerState -match '(?i)deallocated') {
                $vmDeallocated = $true
                break
            }
        }
        else {
            Write-Warning "Azure returned no readable power state. Will retry."
        }

        if ($attempt -lt $maxAttempts) {
            Write-Host "Waiting $retrySeconds seconds before next check..."
            Start-Sleep -Seconds $retrySeconds
        }
    }

    if (-not $vmDeallocated) {
        throw "VM deallocation could not be confirmed after $maxAttempts attempts. Last reported state: '$finalPowerState'. Check Azure Portal and VM permissions."
    }

    # STEP 12: Clear success message after Azure confirms deallocation

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "BHAI, VM SUCCESSFULLY STOP (DEALLOCATED) HO GAYI HAI!"
    Write-Host "VM Name       : $vmName"
    Write-Host "Resource Group: $resourceGroup"
    Write-Host "Power State   : $finalPowerState"
    Write-Host "Request ID    : $requestId"
    Write-Host "VM Deleted    : No"
    Write-Host "============================================================"
    Write-Host ""

    # STEP 13: Update the Table only after confirmed deallocation

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
        $failureStatus = "StoppedTableUpdateFailed"
        throw "VM is deallocated, but Azure Table status update failed. Check Storage Table permissions."
    }

    # STEP 14: Create success summary

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
## Azure VM Deallocation Successful

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

The VM was verified as deallocated. The email notification step may now run.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    # Publish success output ONLY after verification and Table update.
    "vm_stopped=true" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

    Write-Host "Azure Table status updated successfully."
    Write-Host "VM stop verified. Email notification step can now run."
}
catch {
    $operationError = $_.Exception.Message
    $failedAtUtc = [DateTime]::UtcNow.ToString("o")

    if ($requestSaved) {
        if ($vmDeallocated -and $failureStatus -eq "StoppedTableUpdateFailed") {
            $statusToSave = "StoppedTableUpdateFailed"
            $stoppedValue = "true"
        }
        else {
            $statusToSave = "StopFailed"
            $stoppedValue = "false"
        }

        $safeFailure = $operationError -replace '[\r\n]+', ' '

        $failureArguments = @(
            "PartitionKey=$partitionKey"
            "RowKey=$rowKey"
            "RequestStatus=$statusToSave"
            "VmStopped=$stoppedValue"
            "VmDeleted=false"
            "FailureReason=$safeFailure"
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
    }

    $statusForSummary = if ($vmDeallocated) {
        "StoppedTableUpdateFailed"
    }
    else {
        "StopFailed"
    }

    $failureSummary = [ordered]@{
        requestId      = $requestId
        requestStatus  = $statusForSummary
        subscriptionId = $subscriptionId
        resourceGroup  = $resourceGroup
        vmName         = $vmName
        environment    = $environment
        vmStopped      = $vmDeallocated
        vmDeleted      = $false
        finalPowerState = $finalPowerState
        failureReason  = $operationError
        failedAtUtc    = $failedAtUtc
    }

    $failureSummary |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $summaryPath -Encoding utf8

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        @"
## Azure VM Deallocation Failed

- **Request ID:** $requestId
- **VM:** $vmName
- **Status:** $statusForSummary
- **VM Deallocated:** $vmDeallocated
- **VM Deleted:** No
- **Last Power State:** $finalPowerState
- **Error:** $operationError

Email notification will be skipped because this step failed.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    Write-Error "Pipeline stopped. Email notification will not run."
    throw
}
