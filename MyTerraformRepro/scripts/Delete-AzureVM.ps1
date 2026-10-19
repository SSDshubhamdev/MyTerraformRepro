
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
    [string]$ConfirmDeletion,

    # Supply this when resuming after the VM was already deleted.
    [Parameter(Mandatory = $false)]
    [string]$NetworkInterfaceName
)

$ErrorActionPreference = "Stop"

try {
    if ($ConfirmDeletion -ne "yes") {
        throw "Deletion cancelled. Explicit confirmation is required."
    }

    $parsedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse(
        $SubscriptionId,
        [ref]$parsedSubscriptionId
    )) {
        throw "Invalid Azure Subscription ID."
    }

    $context = Get-AzContext
    if (-not $context -or -not $context.Account) {
        throw "Azure PowerShell is not authenticated."
    }

    $subscription = Get-AzSubscription `
        -SubscriptionId $parsedSubscriptionId.ToString() `
        -ErrorAction Stop

    Set-AzContext `
        -SubscriptionId $subscription.Id `
        -ErrorAction Stop | Out-Null

    $context = Get-AzContext
    if ($context.Subscription.Id -ne $parsedSubscriptionId.ToString()) {
        throw "Active subscription does not match the requested subscription."
    }

    $null = Get-AzResourceGroup `
        -Name $ResourceGroupName `
        -ErrorAction Stop

    Write-Host "Subscription and Resource Group validated."

    $validatedNics = @()
    $vm = $null

    # Look for the VM. A missing VM is allowed only for recovery.
    $vm = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction SilentlyContinue

    if ($vm) {
        Write-Host "VM found: $($vm.Name)"

        # Collect NICs before deleting the VM.
        foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
            $nic = Get-AzNetworkInterface `
                -Name (($nicRef.Id -split "/")[-1]) `
                -ResourceGroupName $ResourceGroupName `
                -ErrorAction Stop

            if (-not $nic.VirtualMachine -or
                $nic.VirtualMachine.Id -ine $vm.Id) {
                throw "NIC '$($nic.Name)' is not confirmed as attached to the target VM."
            }

            $validatedNics += $nic
        }

        Write-Host "Deleting VM: $VMName"

        Remove-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $VMName `
            -Force `
            -ErrorAction Stop

        $remainingVM = Get-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $VMName `
            -ErrorAction SilentlyContinue

        if ($remainingVM) {
            throw "VM deletion could not be verified."
        }

        Write-Host "SUCCESS: VM deletion verified."
    }
    else {
        Write-Host "VM '$VMName' is already absent."

        if ([string]::IsNullOrWhiteSpace($NetworkInterfaceName)) {
            throw "VM is already absent. To resume NIC cleanup, provide NetworkInterfaceName."
        }

        # Recovery mode: use the explicitly supplied NIC name.
        $nic = Get-AzNetworkInterface `
            -Name $NetworkInterfaceName `
            -ResourceGroupName $ResourceGroupName `
            -ErrorAction Stop

        $validatedNics += $nic
    }

    # Delete only NICs confirmed to be detached.
    foreach ($originalNic in $validatedNics) {
        $currentNic = Get-AzNetworkInterface `
            -Name $originalNic.Name `
            -ResourceGroupName $originalNic.ResourceGroupName `
            -ErrorAction SilentlyContinue

        if (-not $currentNic) {
            Write-Host "NIC already absent: $($originalNic.Name)"
            continue
        }

        if ($currentNic.VirtualMachine) {
            Write-Warning "Skipping NIC '$($currentNic.Name)': it is still attached to a VM."
            continue
        }

        Write-Host "Deleting detached NIC: $($currentNic.Name)"

        Remove-AzNetworkInterface `
            -Name $currentNic.Name `
            -ResourceGroupName $currentNic.ResourceGroupName `
            -Force `
            -ErrorAction Stop

        $remainingNic = Get-AzNetworkInterface `
            -Name $currentNic.Name `
            -ResourceGroupName $currentNic.ResourceGroupName `
            -ErrorAction SilentlyContinue

        if ($remainingNic) {
            throw "NIC '$($currentNic.Name)' still exists."
        }

        Write-Host "SUCCESS: NIC deletion verified: $($originalNic.Name)"
    }

    Write-Host "SUCCESS: Decommission operation completed."
}
catch {
    Write-Error "VM decommission failed: $($_.Exception.Message)"
    throw
}
