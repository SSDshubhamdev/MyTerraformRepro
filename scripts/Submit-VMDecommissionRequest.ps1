
$ErrorActionPreference = "Stop"

# =========================================================
# 1. Read and validate inputs
# =========================================================

$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$tenantId       = $env:AZURE_TENANT_ID
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME
$webhook        = $env:DECOMMISSION_NOTIFICATION_WEBHOOK

$requiredInputs = @{
    SUBSCRIPTION_ID = $subscriptionId
    RESOURCE_GROUP  = $resourceGroup
    VM_NAME         = $vmName
    VM_ENVIRONMENT  = $environment
    REQUESTER       = $requester
    AZURE_TENANT_ID = $tenantId
    STORAGE_ACCOUNT = $storageAccount
    TABLE_NAME      = $tableName
}

foreach ($key in $requiredInputs.Keys) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredInputs[$key])) {
        throw "Required input is missing: $key"
    }
}

if ($environment -notin @("Dev", "Prod")) {
    throw "Environment must be Dev or Prod."
}

$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($subscriptionId, [ref]$parsedGuid)) {
    throw "SUBSCRIPTION_ID must be a valid GUID."
}

if ($requester.Length -gt 200) {
    throw "REQUESTER must not exceed 200 characters."
}

$waitDays = if ($environment -eq "Prod") { 11 } else { 7 }

$createdUtc = [DateTimeOffset]::UtcNow
$eligibilityUtc = $createdUtc.AddDays($waitDays)
$requestId = [guid]::NewGuid().ToString()

$summaryPath = Join-Path $env:GITHUB_WORKSPACE "decommission-request-summary.json"

Write-Host "Request ID: $requestId"
Write-Host "Environment: $environment"
Write-Host "Resource Group: $resourceGroup"
Write-Host "VM: $vmName"
Write-Host "Storage Account: $storageAccount"
Write-Host "Table: $tableName"
Write-Host "Scheduled eligibility UTC: $($eligibilityUtc.ToString('o'))"

# =========================================================
# 2. Azure CLI helper with detailed error output
# =========================================================

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $output = @(& az @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { "$_" }) -join "`n"

    if ($exitCode -ne 0) {
        Write-Host "Azure CLI operation failed: $Operation"
        Write-Host "Exit code: $exitCode"
        Write-Host "Azure CLI response:"
        Write-Host $outputText

        throw "$Operation failed. See the detailed Azure CLI response above."
    }

    return $outputText
}

# =========================================================
# 3. Verify tenant and select the requested subscription
# =========================================================

$context = Get-AzContext

if ($null -eq $context -or $null -eq $context.Tenant) {
    throw "Azure PowerShell context is missing. Check Azure OIDC login."
}

Write-Host "Current tenant ID: $($context.Tenant.Id)"
Write-Host "Requested tenant ID: $tenantId"
Write-Host "Current subscription ID: $($context.Subscription.Id)"
Write-Host "Requested subscription ID: $subscriptionId"

if ($context.Tenant.Id -ne $tenantId) {
    throw "Tenant mismatch. Verify AZURE_TENANT_ID and the OIDC app registration."
}

if (
    $null -eq $context.Subscription -or
    $context.Subscription.Id -ne $subscriptionId
) {
    Write-Host "Requested subscription is not selected. Checking access..."

    $subscription = Get-AzSubscription `
        -TenantId $tenantId `
        -SubscriptionId $subscriptionId `
        -ErrorAction Stop

    if ($null -eq $subscription) {
        throw "Requested subscription was not found in the configured tenant or the identity has no access."
    }

    Set-AzContext `
        -SubscriptionObject $subscription `
        -ErrorAction Stop | Out-Null
}

$context = Get-AzContext

if (
    $null -eq $context.Subscription -or
    $context.Subscription.Id -ne $subscriptionId
) {
    throw "Azure subscription context verification failed."
}

Write-Host "Azure subscription context verified."

# =========================================================
# 4. Verify Azure CLI identity and subscription
# =========================================================

$accountJson = Invoke-AzCli `
    -Arguments @("account", "show", "--output", "json") `
    -Operation "Azure CLI account verification"

$cliAccount = $accountJson | ConvertFrom-Json

if ($cliAccount.id -ne $subscriptionId) {
    throw "Azure CLI subscription does not match SUBSCRIPTION_ID."
}

if ($cliAccount.tenantId -ne $tenantId) {
    throw "Azure CLI tenant does not match AZURE_TENANT_ID."
}

Write-Host "Azure CLI tenant and subscription verified."

# =========================================================
# 5. Validate VM and inventory dependencies
# =========================================================

$vm = Get-AzVM `
    -ResourceGroupName $resourceGroup `
    -Name $vmName `
    -ErrorAction Stop

Write-Host "VM found: $($vm.Name)"
Write-Host "VM Resource ID: $($vm.Id)"

$nicIds = @(
    $vm.NetworkProfile.NetworkInterfaces |
    ForEach-Object { $_.Id } |
    Where-Object { $_ } |
    Sort-Object -Unique
)

$nicInventory = [System.Collections.Generic.List[object]]::new()
$publicIpIds = [System.Collections.Generic.List[string]]::new()
$nsgIds = [System.Collections.Generic.List[string]]::new()

foreach ($nicId in $nicIds) {
    $parts = $nicId.Trim("/").Split("/")
    $rgIndex = [Array]::IndexOf($parts, "resourceGroups")

    if ($rgIndex -lt 0 -or $rgIndex + 1 -ge $parts.Length) {
        throw "Unable to parse NIC resource ID: $nicId"
    }

    $nicRg = $parts[$rgIndex + 1]
    $nicName = $parts[-1]

    $nic = Get-AzNetworkInterface `
        -ResourceGroupName $nicRg `
        -Name $nicName `
        -ErrorAction Stop

    $nicPublicIps = @(
        $nic.IpConfigurations |
        ForEach-Object { $_.PublicIpAddress.Id } |
        Where-Object { $_ } |
        Sort-Object -Unique
    )

    $nicNsgIds = @()
    if ($nic.NetworkSecurityGroup -and $nic.NetworkSecurityGroup.Id) {
        $nicNsgIds += $nic.NetworkSecurityGroup.Id
    }

    foreach ($id in $nicPublicIps) {
        $publicIpIds.Add([string]$id)
    }

    foreach ($id in $nicNsgIds) {
        $nsgIds.Add([string]$id)
    }

    $subnetIds = @(
        $nic.IpConfigurations |
        ForEach-Object { $_.Subnet.Id } |
        Where-Object { $_ } |
        Sort-Object -Unique
    )

    $nicInventory.Add([pscustomobject]@{
        Name                    = $nic.Name
        ResourceId              = $nic.Id
        Location                = $nic.Location
        PublicIPIds             = $nicPublicIps
        NetworkSecurityGroupIds = $nicNsgIds
        SubnetIds               = $subnetIds
    })
}

$publicIpIds = @($publicIpIds | Sort-Object -Unique)
$nsgIds = @($nsgIds | Sort-Object -Unique)

$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

$dataDisks = @(
    $vm.StorageProfile.DataDisks |
    ForEach-Object {
        [pscustomobject]@{
            Name          = $_.Name
            Lun           = $_.Lun
            ManagedDiskId = $_.ManagedDisk.Id
        }
    }
)

Write-Host "NIC count: $($nicIds.Count)"
Write-Host "Public IP count: $($publicIpIds.Count)"
Write-Host "NIC-associated NSG count: $($nsgIds.Count)"
Write-Host "Data disk count: $($dataDisks.Count)"

$inventory = [ordered]@{
    VMName                  = $vm.Name
    VMResourceId            = $vm.Id
    Location                = $vm.Location
    ResourceGroup           = $resourceGroup
    SubscriptionId          = $subscriptionId
    NICs                    = @($nicInventory)
    PublicIPIds             = @($publicIpIds)
    NetworkSecurityGroupIds = @($nsgIds)
    OSDiskId                = $osDiskId
    DataDisks               = @($dataDisks)
}

# =========================================================
# 6. Build request and write a diagnostic summary
# =========================================================

$partitionKey = $environment
$rowKey = $requestId

$request = [ordered]@{
    RequestId                 = $requestId
    RequestStatus             = "PendingApproval"
    Environment               = $environment
    Requester                 = $requester
    SubscriptionId            = $subscriptionId
    ResourceGroup             = $resourceGroup
    VMName                    = $vm.Name
    VMResourceId              = $vm.Id
    CreatedUtc                = $createdUtc.ToString("o")
    ScheduledEligibilityUtc   = $eligibilityUtc.ToString("o")
    WaitDays                  = $waitDays
    ResourceInventory         = $inventory
    StorageStatus             = "Pending"
    NotificationStatus        = "NotConfigured"
}

$request |
    ConvertTo-Json -Depth 15 |
    Set-Content -Path $summaryPath -Encoding utf8

# =========================================================
# 7. Check Table Storage access and table existence
# =========================================================

Write-Host "Checking Table Storage access..."

$existsJson = Invoke-AzCli `
    -Arguments @(
        "storage", "table", "exists",
        "--account-name", $storageAccount,
        "--name", $tableName,
        "--auth-mode", "login",
        "--output", "json"
    ) `
    -Operation "Storage Table existence check"

$existsResult = $existsJson | ConvertFrom-Json

if (-not $existsResult.exists) {
    Write-Host "Table does not exist. Attempting to create it..."

    $null = Invoke-AzCli `
        -Arguments @(
            "storage", "table", "create",
            "--account-name", $storageAccount,
            "--name", $tableName,
            "--auth-mode", "login",
            "--output", "json"
        ) `
        -Operation "Storage Table creation"
}

Write-Host "Storage Table existence check passed."

# =========================================================
# 8. Insert entity into Table Storage
# =========================================================

# Store inventory as JSON text in one Table property.
# The whole key=value pair is passed as a single CLI argument.

$inventoryJson = $inventory | ConvertTo-Json -Depth 15 -Compress

$entityProperties = @(
    "PartitionKey=$partitionKey"
    "RowKey=$rowKey"
    "RequestId=$requestId"
    "RequestStatus=PendingApproval"
    "Environment=$environment"
    "Requester=$requester"
    "SubscriptionId=$subscriptionId"
    "ResourceGroup=$resourceGroup"
    "VMName=$($vm.Name)"
    "VMResourceId=$($vm.Id)"
    "CreatedUtc=$($createdUtc.ToString('o'))"
    "ScheduledEligibilityUtc=$($eligibilityUtc.ToString('o'))"
    "WaitDays=$waitDays"
    "ResourceInventoryJson=$inventoryJson"
)

Write-Host "Inserting request entity..."

$insertArguments = @(
    "storage", "entity", "insert",
    "--account-name", $storageAccount,
    "--table-name", $tableName,
    "--auth-mode", "login",
    "--output", "json",
    "--entity"
) + $entityProperties

$insertResponse = Invoke-AzCli `
    -Arguments $insertArguments `
    -Operation "Storage Table entity insert"

Write-Host "Table insert response:"
Write-Host $insertResponse

$request.StorageStatus = "Saved"

# =========================================================
# 9. Optional notification webhook
# =========================================================

if (-not [string]::IsNullOrWhiteSpace($webhook)) {
    if (-not $webhook.StartsWith("https://")) {
        throw "DECOMMISSION_NOTIFICATION_WEBHOOK must use HTTPS."
    }

    $notificationPayload = [ordered]@{
        event          = "VMDecommissionRequestCreated"
        requestId      = $requestId
        environment    = $environment
        requester      = $requester
        vmName         = $vm.Name
        resourceGroup  = $resourceGroup
        status         = "PendingApproval"
        eligibilityUtc = $eligibilityUtc.ToString("o")
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod `
            -Uri $webhook `
            -Method Post `
            -ContentType "application/json" `
            -Body $notificationPayload `
            -ErrorAction Stop | Out-Null

        $request.NotificationStatus = "Sent"
        Write-Host "Notification sent."
    }
    catch {
        $request.NotificationStatus = "Failed"
        Write-Warning "Request was saved, but notification failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host "Notification webhook not configured; skipping notification."
}

# =========================================================
# 10. Save final summary
# =========================================================

$request |
    ConvertTo-Json -Depth 15 |
    Set-Content -Path $summaryPath -Encoding utf8

Write-Host "============================================="
Write-Host "DECOMMISSION REQUEST CREATED"
Write-Host "Request ID: $requestId"
Write-Host "Status: PendingApproval"
Write-Host "Storage status: $($request.StorageStatus)"
Write-Host "Notification status: $($request.NotificationStatus)"
Write-Host "Eligibility UTC: $($eligibilityUtc.ToString('o'))"
Write-Host "No Azure resources were deleted."
Write-Host "============================================="
