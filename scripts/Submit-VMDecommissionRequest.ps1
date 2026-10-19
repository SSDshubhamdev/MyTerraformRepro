
$ErrorActionPreference = "Stop"

# --------------------------------------------------
# 1. Read pipeline inputs
# --------------------------------------------------
$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME
$webhookUrl     = $env:DECOMMISSION_NOTIFICATION_WEBHOOK

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or
    [string]::IsNullOrWhiteSpace($resourceGroup) -or
    [string]::IsNullOrWhiteSpace($vmName) -or
    [string]::IsNullOrWhiteSpace($requester)) {
    throw "Required pipeline inputs are missing."
}

if ($environment -notin @("Dev", "Prod")) {
    throw "Environment must be Dev or Prod."
}

$parsedSubscriptionId = [guid]::Empty
if (-not [guid]::TryParse($subscriptionId, [ref]$parsedSubscriptionId)) {
    throw "Subscription ID is not a valid GUID."
}

if ($environment -eq "Dev") {
    $waitingDays = 7
}
else {
    $waitingDays = 11
}

$requestId = [guid]::NewGuid().ToString()
$requestedAt = [DateTime]::UtcNow
$scheduledAt = $requestedAt.AddDays($waitingDays)

Write-Host "Request ID: $requestId"
Write-Host "Environment: $environment"
Write-Host "Scheduled eligibility date (UTC): $($scheduledAt.ToString('o'))"

# --------------------------------------------------
# 2. Select and validate Azure subscription
# --------------------------------------------------
Set-AzContext -SubscriptionId $subscriptionId | Out-Null

$context = Get-AzContext
if ($context.Subscription.Id -ne $subscriptionId) {
    throw "Azure subscription context does not match the requested subscription."
}

$vm = Get-AzVM `
    -ResourceGroupName $resourceGroup `
    -Name $vmName `
    -ErrorAction Stop

if (-not $vm.Id) {
    throw "VM resource ID was not returned."
}

Write-Host "VM found: $($vm.Name)"
Write-Host "VM ID: $($vm.Id)"

# --------------------------------------------------
# 3. Collect and validate VM dependencies
# --------------------------------------------------
$nicIds = @(
    $vm.NetworkProfile.NetworkInterfaces |
        ForEach-Object { $_.Id } |
        Where-Object { $_ }
)

if ($nicIds.Count -eq 0) {
    throw "No NICs are attached to this VM. Manual review is required."
}

$nicInventory = @()
$publicIpIds = @()
$nsgIds = @()

foreach ($nicId in $nicIds) {
    $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop

    $attachedVmId = $nic.VirtualMachine.Id

    if (-not $attachedVmId -or
        $attachedVmId.TrimEnd("/") -ine $vm.Id.TrimEnd("/")) {
        throw "NIC attachment validation failed: $nicId"
    }

    $nicPublicIps = @(
        $nic.IpConfigurations |
            ForEach-Object { $_.PublicIpAddress.Id } |
            Where-Object { $_ }
    )

    $nicNsgId = $nic.NetworkSecurityGroup.Id

    if ($nicNsgId) {
        $nsgIds += $nicNsgId
    }

    $publicIpIds += $nicPublicIps

    $nicInventory += [PSCustomObject]@{
        Name           = $nic.Name
        ResourceId     = $nic.Id
        PublicIPIds    = @($nicPublicIps)
        NetworkSecurityGroupId = $nicNsgId
    }
}

$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

$dataDiskIds = @(
    $vm.StorageProfile.DataDisks |
        ForEach-Object { $_.ManagedDisk.Id } |
        Where-Object { $_ }
)

# Remove duplicate IDs from inventory
$publicIpIds = @($publicIpIds | Sort-Object -Unique)
$nsgIds = @($nsgIds | Sort-Object -Unique)

$inventory = [PSCustomObject]@{
    RequestId            = $requestId
    SubscriptionId       = $subscriptionId
    ResourceGroupName    = $resourceGroup
    VMName               = $vm.Name
    VMResourceId         = $vm.Id
    Environment          = $environment
    Location             = $vm.Location
    NICs                 = @($nicInventory)
    PublicIPResourceIds  = @($publicIpIds)
    NSGResourceIds       = @($nsgIds)
    OSDiskResourceId     = $osDiskId
    DataDiskResourceIds  = @($dataDiskIds)
    RequestedBy          = $requester
    RequestedAtUtc       = $requestedAt.ToString("o")
    ScheduledDeletionAtUtc = $scheduledAt.ToString("o")
    ApprovalStatus       = "Pending"
    DecommissionStatus   = "PendingApproval"
}

Write-Host "Dependency inventory completed."
Write-Host "NIC count: $($nicInventory.Count)"
Write-Host "Public IP count: $($publicIpIds.Count)"
Write-Host "NSG count: $($nsgIds.Count)"
Write-Host "Data disk count: $($dataDiskIds.Count)"

# --------------------------------------------------
# 4. Create the Azure Table if it does not exist
# --------------------------------------------------
$null = & az storage table create `
    --name $tableName `
    --account-name $storageAccount `
    --auth-mode login `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Could not create/access the Azure Storage Table."
}

# --------------------------------------------------
# 5. Save request in Azure Table Storage
# --------------------------------------------------
$nicJson = ConvertTo-Json -InputObject @($nicInventory) -Depth 10 -Compress
$publicIpJson = ConvertTo-Json -InputObject @($publicIpIds) -Compress
$nsgJson = ConvertTo-Json -InputObject @($nsgIds) -Compress
$dataDiskJson = ConvertTo-Json -InputObject @($dataDiskIds) -Compress

$entityArgs = @(
    "PartitionKey=$subscriptionId"
    "RowKey=$requestId"
    "RequestId=$requestId"
    "ResourceGroupName=$resourceGroup"
    "VMName=$($vm.Name)"
    "VMResourceId=$($vm.Id)"
    "Environment=$environment"
    "Location=$($vm.Location)"
    "NICsJson=$nicJson"
    "PublicIPResourceIdsJson=$publicIpJson"
    "NSGResourceIdsJson=$nsgJson"
    "OSDiskResourceId=$osDiskId"
    "DataDiskResourceIdsJson=$dataDiskJson"
    "RequestedBy=$requester"
    "RequestedAtUtc=$($requestedAt.ToString('o'))"
    "ScheduledDeletionAtUtc=$($scheduledAt.ToString('o'))"
    "ApprovalStatus=Pending"
    "DecommissionStatus=PendingApproval"
    "NotificationStatus=Pending"
)

$null = & az storage entity insert `
    --account-name $storageAccount `
    --table-name $tableName `
    --auth-mode login `
    --if-exists fail `
    --entity @entityArgs `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Failed to insert the decommission request into Azure Table Storage."
}

Write-Host "Request saved to $storageAccount/$tableName"

# --------------------------------------------------
# 6. Create a request summary artifact
# --------------------------------------------------
$summary = [PSCustomObject]@{
    RequestId = $requestId
    SubscriptionId = $subscriptionId
    ResourceGroupName = $resourceGroup
    VMName = $vm.Name
    Environment = $environment
    RequestedAtUtc = $requestedAt.ToString("o")
    ScheduledDeletionAtUtc = $scheduledAt.ToString("o")
    ApprovalStatus = "Pending"
    DecommissionStatus = "PendingApproval"
    NotificationStatus = "Pending"
}

$summary |
    ConvertTo-Json -Depth 5 |
    Set-Content -Path "decommission-request-summary.json" -Encoding utf8

# --------------------------------------------------
# 7. Notify customer using an HTTPS webhook
# --------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($webhookUrl)) {
    if ($webhookUrl -notmatch '^https://') {
        throw "Notification webhook must use HTTPS."
    }

    $payload = @{
        event = "AzureVMDecommissionRequested"
        requestId = $requestId
        subscriptionId = $subscriptionId
        resourceGroup = $resourceGroup
        vmName = $vm.Name
        environment = $environment
        requestedBy = $requester
        scheduledDeletionAtUtc = $scheduledAt.ToString("o")
        approvalStatus = "Pending"
        message = "A decommission request has been raised. The scheduled date is the earliest planned deletion date, subject to required approval and final validation. No resources have been deleted."
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Uri $webhookUrl `
        -Method Post `
        -ContentType "application/json" `
        -Body $payload `
        -ErrorAction Stop | Out-Null

    $null = & az storage entity merge `
        --account-name $storageAccount `
        --table-name $tableName `
        --auth-mode login `
        --partition-key $subscriptionId `
        --row-key $requestId `
        --entity "NotificationStatus=Sent" "NotificationSentAtUtc=$([DateTime]::UtcNow.ToString('o'))" `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Notification was sent, but the notification status could not be updated in Table Storage."
    }

    Write-Host "Customer notification sent."
}
else {
    Write-Warning "Notification webhook is not configured. Request is saved, but no customer notification was sent."
}

Write-Host "Pipeline 1 completed. No Azure resources were deleted."
Write-Host "Request ID for tracking: $requestId"
