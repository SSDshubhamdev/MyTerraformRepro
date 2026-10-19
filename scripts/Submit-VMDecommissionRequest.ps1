
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission Request
# Authentication : GitHub Actions OIDC
# Storage Account: shubhamstorage11
# Table          : VMDecommissionRequests
# Action         : Validate and save request only
# ============================================================

# STEP 1: Validate inputs

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

# Correct PowerShell syntax for environment validation.
$allowedEnvironments = @("Dev", "Prod")

if ($environment -notin $allowedEnvironments) {
    throw "Invalid environment '$environment'. Allowed values: Dev, Prod."
}

if ($environment -eq "Dev") {
    $waitDays = 7
}
else {
    $waitDays = 11
}

Write-Host "Environment: $environment"
Write-Host "Waiting period: $waitDays days"

# STEP 2: Azure CLI helper functions

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String).Trim()

    if ($outputText) {
        Write-Host $outputText
    }

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed with exit code $exitCode. Details: $outputText"
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
        throw "Failed to parse Azure CLI JSON output: $outputText"
    }
}

# STEP 3: Verify OIDC identity and subscription

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
    throw "Tenant mismatch. Check AZURE_TENANT_ID."
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
    throw "Subscription mismatch. Check SUBSCRIPTION_ID."
}

Write-Host "Azure tenant and subscription verified."

# STEP 4: Validate the VM

Write-Host "=== STEP 2: Validate VM ===" -ForegroundColor Yellow

$vm = Invoke-AzCliJson -Arguments @(
    "vm", "show",
    "--resource-group", $resourceGroup,
    "--name", $vmName,
    "--output", "json"
)

if (-not $vm -or -not $vm.id) {
    throw "VM '$vmName' was not found in '$resourceGroup'."
}

Write-Host "VM Name: $($vm.name)"
Write-Host "VM Resource ID: $($vm.id)"
Write-Host "VM Location: $($vm.location)"

# STEP 5: Collect dependencies

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

# STEP 6: Verify the table exists

Write-Host "=== STEP 4: Verify Storage Table ===" -ForegroundColor Yellow

$tableResult = Invoke-AzCliJson -Arguments @(
    "storage", "table", "exists",
    "--account-name", $storageAccount,
    "--name", $tableName,
    "--auth-mode", "login",
    "--output", "json"
)

if (-not $tableResult.exists) {

    Write-Host "Table missing. Creating table..."

    Invoke-AzCliJson -Arguments @(
        "storage", "table", "create",
        "--account-name", $storageAccount,
        "--name", $tableName,
        "--auth-mode", "login",
        "--output", "json"
    )

    Write-Host "Table creation completed."
}
else {
    Write-Host "Table already exists: $tableName"
}

# STEP 7: Build the entity

Write-Host "=== STEP 5: Prepare request ===" -ForegroundColor Yellow

$requestId = [guid]::NewGuid().ToString()
$createdUtc = [DateTime]::UtcNow
$scheduledUtc = $createdUtc.AddDays($waitDays)

$inventoryJson = $inventory | ConvertTo-Json -Depth 50 -Compress

# Azure Table keys cannot contain /, \, #, ?, or control characters.
$partitionKey = $subscriptionId
$rowKey = $requestId

# Azure Tables limits a single property to 64 KiB.
# Reject oversized inventory rather than silently truncating it.
$inventoryBytes = [System.Text.Encoding]::UTF8.GetByteCount($inventoryJson)

if ($inventoryBytes -gt 60000) {
    throw "Resource inventory JSON is too large for one Table property ($inventoryBytes bytes). Store the inventory in a Blob and save its URI in the table instead."
}

Write-Host "Request ID: $requestId"
Write-Host "Target table: $tableName"

# STEP 8: Insert entity using separate key=value arguments.
# FIX: Do not pass --entity "@file"; Azure CLI parses it as a
# property declaration and raises the dictionary update error.

Write-Host "=== STEP 6: Insert request into Azure Table ===" -ForegroundColor Yellow

$entityProperties = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=PendingApproval"
    "Environment=$environment"
    "Requester=$requester"
    "SubscriptionId=$subscriptionId"
    "ResourceGroup=$resourceGroup"
    "VMName=$vmName"
    "VMResourceId=$($vm.id)"
    "CreatedUtc=$($createdUtc.ToString('o'))"
    "ScheduledEligibilityUtc=$($scheduledUtc.ToString('o'))"
    "WaitDays=$waitDays"
    "ResourceInventoryJson=$inventoryJson"
)

$insertArguments = @(
    "storage"
    "entity"
    "insert"
    "--account-name"
    $storageAccount
    "--table-name"
    $tableName
    "--auth-mode"
    "login"
    "--entity"
) + $entityProperties + @(
    "--output"
    "json"
)

try {
    $insertOutput = Invoke-AzCli -Arguments $insertArguments
    Write-Host "Request entity inserted successfully." -ForegroundColor Green
}
catch {
    throw "Failed to insert request into '$tableName'. Azure CLI details: $($_.Exception.Message)"
}

# STEP 9: Save a summary artifact

Write-Host "=== STEP 7: Create summary ===" -ForegroundColor Yellow

$summary = [PSCustomObject]@{
    RequestId               = $requestId
    RequestStatus           = "PendingApproval"
    SubscriptionId          = $subscriptionId
    ResourceGroup            = $resourceGroup
    VMName                  = $vm.name
    Environment             = $environment
    Requester               = $requester
    CreatedUtc              = $createdUtc.ToString("o")
    ScheduledEligibilityUtc = $scheduledUtc.ToString("o")
    WaitDays                = $waitDays
    StorageAccount          = $storageAccount
    TableName                = $tableName
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
