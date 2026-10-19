
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("yes", "no")]
    [string]$ConfirmDeletion
)

$ErrorActionPreference = "Stop"

try {
    # Step 1: Require explicit confirmation.
    if ($ConfirmDeletion -ne "yes") {
        throw "Deletion cancelled. Explicit confirmation is required."
    }

    # Step 2: Validate subscription ID.
    $parsedSubscriptionId = [guid]::Empty

    if (-not [guid]::TryParse(
        $SubscriptionId,
        [ref]$parsedSubscriptionId
    )) {
        throw "Invalid Azure Subscription ID."
    }

    # Step 3: Verify Azure OIDC/PowerShell authentication.
    $context = Get-AzContext

    if (-not $context -or -not $context.Account) {
        throw "Azure PowerShell is not authenticated. Check the OIDC login."
    }

    # Select the requested subscription.
    $subscription = Get-AzSubscription `
        -SubscriptionId $parsedSubscriptionId.ToString() `
        -ErrorAction Stop

    if (-not $subscription) {
        throw "Requested subscription is not accessible."
    }

    Set-AzContext `
        -SubscriptionId $parsedSubscriptionId.ToString() `
        -ErrorAction Stop | Out-Null

    $context = Get-AzContext

    if ($context.Subscription.Id -ne $parsedSubscriptionId.ToString()) {
        throw "Active subscription does not match the requested subscription."
    }

    Write-Host "Subscription validated: $($context.Subscription.Id)"

    # Step 4: Validate Resource Group.
    $resourceGroup = Get-AzResourceGroup `
        -Name $ResourceGroupName `
        -ErrorAction Stop

    Write-Host "Resource Group validated: $($resourceGroup.ResourceGroupName)"

    # Step 5: Find and validate the VM.
    $vm = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction Stop

    Write-Host "VM found: $($vm.Name)"
    Write-Host "VM resource ID: $($vm.Id)"
    Write-Host "Location: $($vm.Location)"

    # Step 6: Collect NIC IDs before deleting the VM.
    $nicIds = @(
        $vm.NetworkProfile.NetworkInterfaces |
            ForEach-Object { $_.Id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($nicIds.Count -eq 0) {
        Write-Host "No NICs are attached to this VM."
    }

    # Validate every NIC before making any deletion changes.
    $validatedNics = @()

    foreach ($nicId in $nicIds) {
        $nic = Get-AzNetworkInterface `
            -ResourceId $nicId `
            -ErrorAction Stop

        Write-Host "NIC found: $($nic.Name)"
        Write-Host "NIC resource ID: $($nic.Id)"

        # Only proceed with NICs attached to the selected VM.
        if (-not $nic.VirtualMachine -or
            $nic.VirtualMachine.Id -ine $vm.Id) {
            throw "NIC '$($nic.Name)' is not confirmed as attached to the target VM. No resources have been deleted."
        }

        $validatedNics += $nic
    }

    Write-Host "All target NICs validated."
    Write-Host "Deleting VM resource: $VMName"

    # Step 7: Delete the VM only.
    Remove-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -Force `
        -ErrorAction Stop

    # Step 8: Verify VM deletion before proceeding.
    $remainingVM = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction SilentlyContinue

    if ($null -ne $remainingVM) {
        throw "VM '$VMName' still exists. NIC deletion has been stopped."
    }

    Write-Host "SUCCESS: VM deletion verified."

    # Step 9: Delete only NICs that are now detached.
    foreach ($originalNic in $validatedNics) {
        $nicId = $originalNic.Id

        # Refresh NIC state after VM deletion.
        $currentNic = Get-AzNetworkInterface `
            -ResourceId $nicId `
            -ErrorAction SilentlyContinue

        if ($null -eq $currentNic) {
            Write-Host "NIC already absent: $nicId"
            continue
        }

        if ($currentNic.VirtualMachine) {
            Write-Warning "Skipping NIC '$($currentNic.Name)': it is still attached to a VM."
            continue
        }

        Write-Host "Deleting detached NIC: $($currentNic.Name)"

        Remove-AzNetworkInterface `
            -ResourceId $nicId `
            -Force `
            -ErrorAction Stop

        # Verify NIC deletion.
        $remainingNic = Get-AzNetworkInterface `
            -ResourceId $nicId `
            -ErrorAction SilentlyContinue

        if ($null -ne $remainingNic) {
            throw "NIC '$($currentNic.Name)' still exists. Investigate deletion status."
        }

        Write-Host "SUCCESS: NIC deletion verified: $($currentNic.Name)"
    }

    Write-Host "Decommission operation completed."
    Write-Host "VM: $VMName"
    Write-Host "Resource Group: $ResourceGroupName"
    Write-Host "Subscription: $($context.Subscription.Id)"
}
catch {
    Write-Error "VM decommission failed: $($_.Exception.Message)"
    throw
}
