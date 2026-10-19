
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request
# Authentication: GitHub Actions OIDC
# Storage Account: shubhamstorage11
# Table: VMDecommissionRequests
# IMPORTANT: This script does not delete the VM.
# ============================================================

# STEP 1: Validate required environment variables

$requiredVariables = @(
    "SUBSCRIPTION_ID",
    "RESOURCE_GROUP",
    "VM_NAME",
    "VM_ENVIRONMENT",
    "REQUESTER",
    "AZURE_TENANT_ID",
    "STORAGE_ACCOUNT",
    "TABLE_NAME"
)

foreach ($key in $requiredVariables) {
    $value = [Environment]::GetEnvironmentVariable($key)

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required input is missing: $key"
    }
}

$subscriptionId = $env:SUBSCRIPTION_ID.Trim()
$resourceGroup  = $env:RESOURCE_GROUP.Trim()
$vmName         = $env:VM_NAME.Trim()
$environment    = $env:VM_ENVIRONMENT.Trim()
$requester      = $env:REQUESTER.Trim()
$tenantId       = $env:AZURE_TENANT_ID.Trim()
$storageAccount = $env:STORAGE_ACCOUNT.Trim()
$tableName      = $env:TABLE_NAME.Trim()

# FIX: Valid PowerShell array syntax. Do not use "- Dev"
# inside a PowerShell array.

$allowedEnvironments = @("Dev", "Prod")

if ($environment -notin $allowedEnvironments) {
    throw "Invalid environment '$environment'. Allowed values: Dev, Prod."
}

if ($environment -eq "Dev") {
    $waitDays = 7
}
elseif ($environment -eq "Prod") {
    $waitDays = 11
}
else {
    throw "Unable to determine the waiting period."
}

Write-Host "Environment: $environment"
Write-Host "Waiting period: $waitDays days"

# STEP 2: Azure CLI helper

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "Executing Azure CLI command..." -ForegroundColor Cyan

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String).Trim()

    if ($outputText) {
        Write-Host $outputText
    }

    if ($exitCode -ne 0) {
        throw "Azure CLI failed with exit code $exitCode. Details: $outputText"
    }

    return $outputText
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $outputText = Invoke-AzCli -Arguments $Arguments

    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $null
    }

    try {
        return ($outputText | ConvertFrom-Json)
    }
    catch {
        throw "Unable to parse Azure CLI JSON response: $outputText"
    }
}

# STEP 3: Verify Azure CLI identity and subscription

Write-Host "=== STEP 1: Verify Azure identity ===" -ForegroundColor Yellow

$account = Invoke-AzCliJson -Arguments @(
    "account", "show", "--output", "json"
)

if (-not $account) {
    throw "Azure CLI is not authenticated. Check azure/login@v2."
}

if (-not [string]::Equals(
    [string]$account.tenantId,
    $tenantId,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Tenant mismatch. Check AZURE_TENANT_ID and the OIDC login configuration."
}

Invoke-AzCli -Arguments @(
    "account", "set",
    "--subscription", $subscriptionId
)

$account = Invoke-AzCliJson -Arguments @(
    "account", "show", "--output", "json"
)

if (-not [string]::Equals(
    [string]$account.id,
    $subscriptionId,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Azure CLI subscription does not match SUBSCRIPTION_ID."
}

Write-Host "Azure tenant and subscription verified."

# STEP 4: Validate the requested VM

Write-Host "=== STEP 2: Validate VM ===" -ForegroundColor Yellow

$vm = Invoke-AzCliJson -Arguments @(
    "vm", "show",
    "--resource-group", $resourceGroup,
    "--name", $vmName,
    "--output", "json"
)

if (-not $vm -or -not $vm.id) {
    throw "VM not found: $vmName in resource group $resourceGroup."
}

Write-Host "VM Name: $($vm.name)"
Write-Host "VM ID: $($vm.id)"
Write-Host "Location: $($vm.location)"

# STEP 5: Collect VM dependencies

Write-Host "=== STEP 3: Collect VM dependencies ===" -ForegroundColor Yellow

$nicDetails = @()
$publicIpDetails = @()
$nsgDetails = @()
$subnetDetails = @()

$nicIds = @(
    $vm.networkProfile.networkInterfaces |
        ForEach-Object { $_.id } |
        Where-Object { $_ } |
        Select-Object -Unique
)

foreach ($nicId in $nicIds) {

    $nic = Invoke-AzCliJson -Arguments @(
        "network", "nic", "show",
        "--ids", $nicId,
        "--output", "json"
    )

    $nicDetails += [PSCustomObject]@{
        Name = $nic.name
        Id   = $nic.id
    }

    if ($nic.networkSecurityGroup -and $nic.networkSecurityGroup.id) {
        $nsgDetails += [PSCustomObject]@{
            Name = $nic.networkSecurityGroup.id.Split("/")[-1]
            Id   = $nic.networkSecurityGroup.id
            Type = "NIC"
        }
    }

    foreach ($ipConfig in @($nic.ipConfigurations)) {

        if ($ipConfig.publicIPAddress -and $ipConfig.publicIPAddress.id) {

            $publicIpId = $ipConfig.publicIPAddress.id

            $publicIpDetails += [PSCustomObject]@{
                Name = $publicIpId.Split("/")[-1]
                Id   = $publicIpId
            }
        }

        if ($ipConfig.subnet -and $ipConfig.subnet.id) {

            $subnetId = $ipConfig.subnet.id

            if (-not ($subnetDetails | Where-Object { $_.Id -eq $subnetId })) {

                $subnet = Invoke-AzCliJson -Arguments @(
                    "network", "vnet", "subnet", "show",
                    "--ids", $subnetId,
                    "--output", "json"
                )

                $subnetDetails += [PSCustomObject]@{
                    Name = $subnet.name
                    Id   = $subnet.id
                }

                if ($subnet.networkSecurityGroup -and $subnet.networkSecurityGroup.id) {
                    $nsgDetails += [PSCustomObject]@{
                        Name = $subnet.networkSecurityGroup.id.Split("/")[-1]
                        Id   = $subnet.networkSecurityGroup.id
                        Type = "Subnet"
                    }
                }
            }
        }
    }
}

$publicIpDetails = @($publicIpDetails | Sort-Object Id -Unique)
$nsgDetails = @($nsgDetails | Sort-Object Id -Unique)

$osDisk = $vm.storageProfile.osDisk

$osDiskDetails = [PSCustomObject]@{
    Name = $osDisk.name
    Id   = if ($osDisk.managedDisk) {
        $osDisk.managedDisk.id
    }
    else {
        $null
    }
}

$dataDiskDetails = @(
    $vm.storageProfile.dataDisks |
        ForEach-Object {
            [PSCustomObject]@{
                Name = $_.name
                Id   = if ($_.managedDisk) {
                    $_.managedDisk.id
                }
                else {
                    $null
                }
                Lun = $_.lun
            }
        }
)

$inventory = [PSCustomObject]@{
    VMName        = $vm.name
    VMResourceId  = $vm.id
    Location      = $vm.location
    VMSize        = $vm.hardwareProfile.vmSize
    NICs          = @($nicDetails)
    PublicIPs     = @($publicIpDetails)
    NSGs          = @($nsgDetails)
    Subnets       = @($subnetDetails)
    OSDisk        = $osDiskDetails
    DataDisks     = @($dataDiskDetails)
    NICCount      = @($nicDetails).Count
    PublicIPCount = @($publicIpDetails).Count
    NSGCount      = @($nsgDetails).Count
    DataDiskCount = @($dataDiskDetails).Count
}

Write-Host "NIC count: $($inventory.NICCount)"
Write-Host "Public IP count: $($inventory.PublicIPCount)"
Write-Host "NSG count: $($inventory.NSGCount)"
Write-Host "Data disk count: $($inventory.DataDiskCount)"

# STEP 6: Check/create the Azure Table

Write-Host "=== STEP 4: Verify Storage Table ===" -ForegroundColor Yellow

$tableResult = Invoke-AzCliJson -Arguments @(
    "storage", "table", "exists",
    "--account-name", $storageAccount,
    "--name", $tableName,
    "--auth-mode", "login",
    "--output", "json"
)

if (-not $tableResult.exists) {

    Write-Host "Table not found. Creating table..."

    Invoke-AzCliJson -Arguments @(
        "storage", "table", "create",
        "--account-name", $storageAccount,
        "--name", $tableName,
        "--auth-mode", "login",
        "--output", "json"
    )

    Write-Host "Table creation command completed."
}
else {
    Write-Host "Table already exists: $tableName"
}

# STEP 7: Create request entity

Write-Host "=== STEP 5: Prepare request entity ===" -ForegroundColor Yellow

$requestId = [guid]::NewGuid().ToString()
$createdUtc = [DateTime]::UtcNow
$scheduledUtc = $createdUtc.AddDays($waitDays)

$inventoryJson = $inventory | ConvertTo-Json -Depth 50 -Compress

# Azure Table keys must not contain /, \, #, ?, or control characters.
$partitionKey = $subscriptionId
$rowKey = $requestId

# Use a JSON entity document rather than splitting property values
# on spaces or "=" in PowerShell.
$entity = [ordered]@{
    PartitionKey            = $partitionKey
    RowKey                  = $rowKey
    RequestId               = $requestId
    RequestStatus           = "PendingApproval"
    Environment             = $environment
    Requester               = $requester
    SubscriptionId          = $subscriptionId
    ResourceGroup           = $resourceGroup
    VMName                  = $vmName
    VMResourceId            = [string]$vm.id
    CreatedUtc              = $createdUtc.ToString("o")
    ScheduledEligibilityUtc = $scheduledUtc.ToString("o")
    WaitDays                = $waitDays
    ResourceInventoryJson   = $inventoryJson
}

$entityFile = Join-Path $PWD "decommission-table-entity.json"

$entity |
    ConvertTo-Json -Depth 50 |
    Set-Content -Path $entityFile -Encoding utf8

Write-Host "Request ID: $requestId"
Write-Host "Table: $tableName"
Write-Host "Status: PendingApproval"

# STEP 8: Insert the entity into Table Storage

Write-Host "=== STEP 6: Insert request into Azure Table ===" -ForegroundColor Yellow

try {
    Invoke-AzCliJson -Arguments @(
        "storage", "entity", "insert",
        "--account-name", $storageAccount,
        "--table-name", $tableName,
        "--auth-mode", "login",
        "--entity", "@$entityFile",
        "--output", "json"
    )
}
catch {
    throw "Failed to insert request into Azure Table '$tableName'. Verify the exact Azure CLI error and Storage Table Data Contributor permissions. Details: $($_.Exception.Message)"
}

Write-Host "Request entity inserted successfully." -ForegroundColor Green

# STEP 9: Create workflow summary artifact

Write-Host "=== STEP 7: Write summary ===" -ForegroundColor Yellow

$summary = [PSCustomObject]@{
    RequestId               = $requestId
    RequestStatus           = "PendingApproval"
    SubscriptionId          = $subscriptionId
    ResourceGroup           = $resourceGroup
    VMName                  = $vm.name
    Environment             = $environment
    Requester               = $requester
    CreatedUtc              = $createdUtc.ToString("o")
    ScheduledEligibilityUtc = $scheduledUtc.ToString("o")
    WaitDays                = $waitDays
    StorageAccount          = $storageAccount
    TableName               = $tableName
    Inventory               = $inventory
}

$summary |
    ConvertTo-Json -Depth 50 |
    Set-Content -Path "decommission-request-summary.json" -Encoding utf8

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DECOMMISSION REQUEST SUBMITTED" -ForegroundColor Green
Write-Host "Request ID: $requestId"
Write-Host "VM: $vmName"
Write-Host "Table: $tableName"
Write-Host "Status: PendingApproval"
Write-Host "VM has NOT been deleted."
Write-Host "========================================" -ForegroundColor Green
