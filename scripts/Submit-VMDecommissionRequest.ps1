
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------
# 1. Read and validate workflow inputs
# ---------------------------------------------------------

$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup   = $env:RESOURCE_GROUP
$vmName          = $env:VM_NAME
$environment     = $env:VM_ENVIRONMENT
$requester       = $env:REQUESTER
$tenantId        = $env:AZURE_TENANT_ID
$storageAccount  = $env:STORAGE_ACCOUNT
$tableName       = $env:TABLE_NAME

foreach ($item in @(
    @{ Name = "SUBSCRIPTION_ID"; Value = $subscriptionId },
    @{ Name = "RESOURCE_GROUP"; Value = $resourceGroup },
    @{ Name = "VM_NAME"; Value = $vmName },
    @{ Name = "VM_ENVIRONMENT"; Value = $environment },
    @{ Name = "REQUESTER"; Value = $requester },
    @{ Name = "AZURE_TENANT_ID"; Value = $tenantId },
    @{ Name = "STORAGE_ACCOUNT"; Value = $storageAccount },
    @{ Name = "TABLE_NAME"; Value = $tableName }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Required workflow input is missing: $($item.Name)"
    }
}

if ($environment -notin @("Dev", "Prod")) {
    throw "Environment must be Dev or Prod."
}

$parsedSubscriptionId = [guid]::Empty
if (-not [guid]::TryParse($subscriptionId, [ref]$parsedSubscriptionId)) {
    throw "SUBSCRIPTION_ID is not a valid GUID."
}

if ($requester.Length -gt 200) {
    throw "REQUESTER must not exceed 200 characters."
}

$waitDays = if ($environment -eq "Prod") { 11 } else { 7 }
$createdUtc = [DateTimeOffset]::UtcNow
$eligibilityUtc = $createdUtc.AddDays($waitDays)

Write-Host "Request ID will be generated."
Write-Host "Environment: $environment"
Write-Host "Scheduled eligibility date UTC: $($eligibilityUtc.ToString('o'))"
Write-Host "Storage account: $storageAccount"
Write-Host "Table: $tableName"

# ---------------------------------------------------------
# 2. Helper: run Azure CLI and expose the real error
# ---------------------------------------------------------

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $result = @(& az @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($result | ForEach-Object { "$_" }) -join "`n"

    if ($exitCode -ne 0) {
        Write-Host "AZURE CLI OPERATION FAILED: $Operation"
        Write-Host "Exit code: $exitCode"
        Write-Host "Azure CLI response:"
        Write-Host $outputText
        throw "$Operation failed. Review the Azure CLI response above."
    }

    return $outputText
}

# ---------------------------------------------------------
# 3. Verify OIDC / Azure PowerShell subscription context
# ---------------------------------------------------------

$context = Get-AzContext

if ($null -eq $context -or $null -eq $context.Subscription) {
    throw "Azure PowerShell context is missing. Check Azure OIDC login."
}

Write-Host "Authenticated account: $($context.Account.Id)"
Write-Host "Configured tenant: $($context.Tenant.Id)"
Write-Host "Selected subscription: $($context.Subscription.Id)"

if ($context.Tenant.Id -ne $tenantId) {
    throw "Azure context tenant does not match AZURE_TENANT_ID."
}

if ($context.Subscription.Id -ne $subscriptionId) {
    throw "Azure context subscription does not match SUBSCRIPTION_ID."
}

Write-Host "Azure subscription context verified."

# ---------------------------------------------------------
# 4. Validate the VM and collect its dependencies
# ---------------------------------------------------------

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

$nicDetails = [System.Collections.Generic.List[object]]::new()
$publicIpIds = [System.Collections.Generic.List[string]]::new()
$nsgIds = [System.Collections.Generic.List[string]]::new()

foreach ($nicId in $nicIds) {
    $nicParts = $nicId.Trim("/").Split("/")
    $rgIndex = [Array]::IndexOf($nicParts, "resourceGroups")

    if ($rgIndex -lt 0 -or $rgIndex + 1 -ge $nicParts.Length) {
        throw "Unable to parse NIC resource ID: $nicId"
    }

    $nicRg = $nicParts[$rgIndex + 1]
    $nicResourceName = $nicParts[-1]

    $nic = Get-AzNetworkInterface `
        -ResourceGroupName $nicRg `
        -Name $nicResourceName `
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

    foreach ($publicIpId in $nicPublicIps) {
        $publicIpIds.Add([string]$publicIpId)
    }

    foreach ($nsgId in $nicNsgIds) {
        $nsgIds.Add([string]$nsgId)
    }

    $nicDetails.Add([pscustomobject]@{
        Name             = $nic.Name
        ResourceId       = $nic.Id
        Location         = $nic.Location
        PublicIPIds      = $nicPublicIps
        NetworkSecurityGroupIds = $nicNsgIds
        SubnetIds        = @(
            $nic.IpConfigurations |
            ForEach-Object { $_.Subnet.Id } |
            Where-Object { $_ } |
            Sort-Object -Unique
        )
    })
}

$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

$dataDiskDetails = @(
    $vm.StorageProfile.DataDisks |
    ForEach-Object {
        [pscustomobject]@{
            Name       = $_.Name
            Lun        = $_.Lun
            ManagedDiskId = $_.ManagedDisk.Id
        }
    }
)

$publicIpIds = @($publicIpIds | Sort-Object -Unique)
$nsgIds = @($nsgIds | Sort-Object -Unique)

Write-Host "NIC count: $($nicIds.Count)"
Write-Host "Public IP count: $($publicIpIds.Count)"
Write-Host "NIC-associated NSG count: $($nsgIds.Count)"
Write-Host "Data disk count: $($dataDiskDetails.Count)"

# ---------------------------------------------------------
# 5. Build the request and inventory
# ---------------------------------------------------------

$requestId = [guid]::NewGuid().ToString()
$partitionKey = $environment
$rowKey = $requestId

$inventory = [ordered]@{
    VMName          = $vm.Name
    VMResourceId    = $vm.Id
    Location        = $vm.Location
    ResourceGroup   = $resourceGroup
    SubscriptionId  = $subscriptionId
    NICs            = @($nicDetails)
    PublicIPIds     = @($publicIpIds)
    NetworkSecurityGroupIds = @($nsgIds)
    OSDiskId        = $osDiskId
    DataDisks       = @($dataDiskDetails)
}

$inventoryJson = $inventory | ConvertTo-Json -Depth 15 -Compress

$request = [ordered]@{
    RequestId             = $requestId
    RequestStatus         = "PendingApproval"
    Environment           = $environment
    Requester             = $requester
    SubscriptionId        = $subscriptionId
    ResourceGroup         = $resourceGroup
    VMName                = $vm.Name
    VMResourceId          = $vm.Id
    CreatedUtc            = $createdUtc.ToString("o")
    ScheduledEligibilityUtc = $eligibilityUtc.ToString("o")
    WaitDays              = $waitDays
    ResourceInventory     = $inventory
}

# Write a summary even if a later Storage operation fails.
$summaryPath = Join-Path $env:GITHUB_WORKSPACE "decommission-request-summary.json"

$request |
    ConvertTo-Json -Depth 15 |
    Set-Content -Path $summaryPath -Encoding utf8

Write-Host "Request ID: $requestId"
Write-Host "Request summary created: $summaryPath"

# ---------------------------------------------------------
# 6. Verify Storage Table access and ensure table exists
# ---------------------------------------------------------

Write-Host "Checking Azure CLI authentication..."
$cliAccount = Invoke-AzCli `
    -Arguments @("account", "show", "--output", "json") `
    -Operation "Azure CLI account check"

$cliAccountObject = $cliAccount | ConvertFrom-Json

if ($cliAccountObject.id -ne $subscriptionId) {
    throw "Azure CLI subscription differs from the requested subscription."
}

if ($cliAccountObject.tenantId -ne $tenantId) {
    throw "Azure CLI tenant differs from AZURE_TENANT_ID."
}

Write-Host "Azure CLI tenant and subscription verified."

Write-Host "Checking Storage Table access..."

$existsOutput = Invoke-AzCli `
    -Arguments @(
        "storage", "table", "exists",
        "--account-name", $storageAccount,
        "--name", $tableName,
        "--auth-mode", "login",
        "--output", "json"
    ) `
    -Operation "Storage Table existence check"

$existsResult = $existsOutput | ConvertFrom-Json

if (-not $existsResult.exists) {
    Write-Host "Table does not exist. Creating it..."

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

# ---------------------------------------------------------
# 7. Insert the request using Microsoft Entra / OIDC auth
# ---------------------------------------------------------

# Azure Table entity properties are passed as separate CLI arguments.
# Keep each key=value pair as one argument to preserve spaces in values.

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

Write-Host "Inserting request into Azure Table Storage..."

$insertArguments = @(
    "storage", "entity", "insert",
    "--account-name", $storageAccount,
    "--table-name", $tableName,
    "--auth-mode", "login",
    "--output", "json",
    "--entity"
) + $entityProperties

$insertOutput = Invoke-AzCli `
    -Arguments $insertArguments `
    -Operation "Azure Table Storage entity insert"

Write-Host "Storage insert response:"
Write-Host $insertOutput
Write-Host "Request successfully saved to Azure Table Storage."

# ---------------------------------------------------------
# 8. Optional notification webhook
# ---------------------------------------------------------

$notificationStatus = "NotConfigured"
$webhook = $env:DECOMMISSION_NOTIFICATION_WEBHOOK

if (-not [string]::IsNullOrWhiteSpace($webhook)) {
    if (-not $webhook.StartsWith("https://")) {
        throw "DECOMMISSION_NOTIFICATION_WEBHOOK must use HTTPS."
    }

    $notificationPayload = [ordered]@{
        event       = "VMDecommissionRequestCreated"
        requestId   = $requestId
        environment = $environment
        requester   = $requester
        vmName      = $vm.Name
        resourceGroup = $resourceGroup
        status      = "PendingApproval"
        eligibilityUtc = $eligibilityUtc.ToString("o")
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod `
            -Uri $webhook `
            -Method Post `
            -ContentType "application/json" `
            -Body $notificationPayload `
            -ErrorAction Stop | Out-Null

        $notificationStatus = "Sent"
        Write-Host "Notification webhook completed."
    }
    catch {
        $notificationStatus = "Failed"
        Write-Warning "Request was saved, but notification failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host "Notification webhook is not configured. Skipping notification."
}

# ---------------------------------------------------------
# 9. Update summary with final status
# ---------------------------------------------------------

$requestSummary = [ordered]@{
    RequestId               = $requestId
    RequestStatus           = "PendingApproval"
    Environment             = $environment
    Requester               = $requester
    SubscriptionId          = $subscriptionId
    ResourceGroup           = $resourceGroup
    VMName                  = $vm.Name
    VMResourceId            = $vm.Id
    CreatedUtc              = $createdUtc.ToString("o")
    ScheduledEligibilityUtc = $eligibilityUtc.ToString("o")
    WaitDays                = $waitDays
    NICCount                = $nicIds.Count
    PublicIPCount           = $publicIpIds.Count
    NetworkSecurityGroupCount = $nsgIds.Count
    DataDiskCount           = $dataDiskDetails.Count
    StorageAccount          = $storageAccount
    TableName               = $tableName
    NotificationStatus      = $notificationStatus
    ResourceInventory       = $inventory
}

$requestSummary |
    ConvertTo-Json -Depth 15 |
    Set-Content -Path $summaryPath -Encoding utf8

Write-Host "---------------------------------------------"
Write-Host "DECOMMISSION REQUEST CREATED"
Write-Host "Request ID: $requestId"
Write-Host "Status: PendingApproval"
Write-Host "Environment: $environment"
Write-Host "Scheduled eligibility UTC: $($eligibilityUtc.ToString('o'))"
Write-Host "Notification: $notificationStatus"
Write-Host "No Azure resources were deleted."
Write-Host "---------------------------------------------"
