
$ErrorActionPreference = "Stop"

# =========================================================
# 1. Read pipeline inputs
# =========================================================
$subscriptionId = $env:SUBSCRIPTION_ID
$resourceGroup  = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$requester      = $env:REQUESTER
$tenantId       = $env:AZURE_TENANT_ID
$storageAccount = $env:STORAGE_ACCOUNT
$tableName      = $env:TABLE_NAME
$webhookUrl     = $env:DECOMMISSION_NOTIFICATION_WEBHOOK

foreach ($item in @(
    @{ Name = "SUBSCRIPTION_ID"; Value = $subscriptionId },
    @{ Name = "RESOURCE_GROUP"; Value = $resourceGroup },
    @{ Name = "VM_NAME"; Value = $vmName },
    @{ Name = "REQUESTER"; Value = $requester },
    @{ Name = "AZURE_TENANT_ID"; Value = $tenantId },
    @{ Name = "STORAGE_ACCOUNT"; Value = $storageAccount },
    @{ Name = "TABLE_NAME"; Value = $tableName }
)) {
    if ([string]::IsNullOrWhiteSpace($item.Value)) {
        throw "Required input is missing: $($item.Name)"
    }
}

if ($environment -notin @("Dev", "Prod")) {
    throw "Environment must be Dev or Prod."
}

$parsedSubscriptionId = [guid]::Empty
if (-not [guid]::TryParse(
    $subscriptionId,
    [ref]$parsedSubscriptionId
)) {
    throw "Subscription ID is not a valid GUID."
}

$waitingDays = if ($environment -eq "Dev") { 7 } else { 11 }

$requestId  = [guid]::NewGuid().ToString()
$requestedAt = [DateTime]::UtcNow
$scheduledAt = $requestedAt.AddDays($waitingDays)

Write-Host "Request ID: $requestId"
Write-Host "Environment: $environment"
Write-Host "Scheduled eligibility date UTC: $($scheduledAt.ToString('o'))"

# =========================================================
# 2. Validate OIDC context, tenant and subscription
# =========================================================
$currentContext = Get-AzContext

if ($null -eq $currentContext -or
    $null -eq $currentContext.Account) {
    throw "Azure PowerShell is not authenticated. Check azure/login@v2 OIDC."
}

Write-Host "Authenticated account: $($currentContext.Account.Id)"
Write-Host "Configured tenant: $tenantId"
Write-Host "Requested subscription: $subscriptionId"

if ($currentContext.Tenant.Id -ne $tenantId) {
    throw "Authenticated Azure tenant does not match AZURE_TENANT_ID. Check GitHub secrets."
}

if ($currentContext.Subscription -and
    $currentContext.Subscription.Id -eq $subscriptionId) {
    Write-Host "Requested subscription already selected by OIDC."
}
else {
    $subscriptions = @(
        Get-AzSubscription -TenantId $tenantId -ErrorAction Stop
    )

    $subscription = $subscriptions |
        Where-Object { $_.Id -eq $subscriptionId } |
        Select-Object -First 1

    if ($null -eq $subscription) {
        throw "Subscription $subscriptionId is not visible in tenant $tenantId. Verify the subscription ID and identity access."
    }

    Set-AzContext `
        -SubscriptionObject $subscription `
        -ErrorAction Stop | Out-Null
}

$verifiedContext = Get-AzContext

if ($null -eq $verifiedContext.Subscription -or
    $verifiedContext.Subscription.Id -ne $subscriptionId) {
    throw "Azure subscription context verification failed."
}

Write-Host "Azure subscription context verified."

# =========================================================
# 3. Validate target VM
# =========================================================
$vm = Get-AzVM `
    -ResourceGroupName $resourceGroup `
    -Name $vmName `
    -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($vm.Id)) {
    throw "VM resource ID was not returned."
}

Write-Host "VM found: $($vm.Name)"
Write-Host "VM Resource ID: $($vm.Id)"

# =========================================================
# 4. Collect VM dependencies
# =========================================================
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
    $nic = Get-AzNetworkInterface `
        -ResourceId $nicId `
        -ErrorAction Stop

    $attachedVmId = $nic.VirtualMachine.Id

    if ([string]::IsNullOrWhiteSpace($attachedVmId) -or
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
        Name = $nic.Name
        ResourceId = $nic.Id
        PublicIPIds = @($nicPublicIps)
        NetworkSecurityGroupId = $nicNsgId
    }
}

$publicIpIds = @($publicIpIds | Sort-Object -Unique)
$nsgIds = @($nsgIds | Sort-Object -Unique)

$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

$dataDiskIds = @(
    $vm.StorageProfile.DataDisks |
        ForEach-Object { $_.ManagedDisk.Id } |
        Where-Object { $_ }
)

Write-Host "NIC count: $($nicInventory.Count)"
Write-Host "Public IP count: $($publicIpIds.Count)"
Write-Host "NSG count: $($nsgIds.Count)"
Write-Host "Data disk count: $($dataDiskIds.Count)"

# =========================================================
# 5. Prepare request summary
# =========================================================
$nicJson = ConvertTo-Json -InputObject @($nicInventory) -Depth 10 -Compress
$publicIpJson = ConvertTo-Json -InputObject @($publicIpIds) -Compress
$nsgJson = ConvertTo-Json -InputObject @($nsgIds) -Compress
$dataDiskJson = ConvertTo-Json -InputObject @($dataDiskIds) -Compress

$summary = [PSCustomObject]@{
    RequestId = $requestId
    SubscriptionId = $subscriptionId
    ResourceGroupName = $resourceGroup
    VMName = $vm.Name
    VMResourceId = $vm.Id
    Environment = $environment
    Location = $vm.Location
    NICs = @($nicInventory)
    PublicIPResourceIds = @($publicIpIds)
    NSGResourceIds = @($nsgIds)
    OSDiskResourceId = $osDiskId
    DataDiskResourceIds = @($dataDiskIds)
    RequestedBy = $requester
    RequestedAtUtc = $requestedAt.ToString("o")
    ScheduledDeletionAtUtc = $scheduledAt.ToString("o")
    ApprovalStatus = "Pending"
    DecommissionStatus = "PendingApproval"
    NotificationStatus = "Pending"
}

$summary |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path "decommission-request-summary.json" -Encoding utf8

# =========================================================
# 6. Create table and save request
# Requires Azure CLI to be authenticated and authorized.
# =========================================================
$null = & az storage table create `
    --name $tableName `
    --account-name $storageAccount `
    --auth-mode login `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Unable to create/access the Azure Table. Check Azure CLI authentication and Storage Table data permissions."
}

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
    throw "Failed to insert request into Azure Table Storage."
}

Write-Host "Request saved to $storageAccount/$tableName"

# =========================================================
# 7. Send notification if webhook is configured
# =========================================================
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
        message = "A decommission request was created. No Azure resources have been deleted."
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
        throw "Notification was sent, but notification status could not be updated."
    }

    Write-Host "Customer notification sent."
}
else {
    Write-Warning "Notification webhook not configured. Request saved, but notification was not sent."
}

Write-Host "Pipeline 1 completed. No Azure resources were deleted."
Write-Host "Request ID: $requestId"
