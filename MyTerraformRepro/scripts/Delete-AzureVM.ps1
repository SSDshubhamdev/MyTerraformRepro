
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
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
    # 1. Require explicit confirmation
    if ($ConfirmDeletion -ne "yes") {
        throw "Deletion cancelled. Set confirm_delete to yes."
    }

    # 2. Validate Azure authentication and subscription
    $context = Get-AzContext

    if (-not $context -or -not $context.Subscription) {
        throw "Azure PowerShell is not authenticated."
    }

    if ($context.Subscription.Id -ne $SubscriptionId) {
        throw "Subscription mismatch. Authenticated subscription: $($context.Subscription.Id); requested: $SubscriptionId"
    }

    Write-Host "Subscription verified: $($context.Subscription.Name)"
    Write-Host "Subscription ID: $($context.Subscription.Id)"
    Write-Host "Resource Group: $ResourceGroupName"
    Write-Host "VM Name: $VMName"

    # 3. Verify Resource Group
    $rg = Get-AzResourceGroup `
        -Name $ResourceGroupName `
        -ErrorAction Stop

    Write-Host "Resource Group verified: $($rg.ResourceGroupName)"

    # 4. Find the exact VM
    $vm = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction Stop

    Write-Host "VM verified: $($vm.Name)"
    Write-Host "VM location: $($vm.Location)"

    # 5. Capture attached NIC IDs BEFORE deleting VM
    $nicIds = @(
        $vm.NetworkProfile.NetworkInterfaces |
        ForEach-Object { $_.Id } |
        Where-Object { $_ }
    )

    $nics = @()

    foreach ($nicId in $nicIds) {
        $nic = Get-AzNetworkInterface `
            -ResourceId $nicId `
            -ErrorAction Stop

        # Ensure NIC belongs to this VM
        if (-not $nic.VirtualMachine -or
            $nic.VirtualMachine.Id -ine $vm.Id) {
            throw "NIC association mismatch: $($nic.Name). Stopping before deletion."
        }

        # Safety: refuse NICs associated with backend pools
        foreach ($ipConfig in $nic.IpConfigurations) {
            if (@($ipConfig.LoadBalancerBackendAddressPools).Count -gt 0) {
                throw "NIC '$($nic.Name)' has a Load Balancer backend association. Review dependencies first."
            }

            if (@($ipConfig.ApplicationGatewayBackendAddressPools).Count -gt 0) {
                throw "NIC '$($nic.Name)' has an Application Gateway backend association. Review dependencies first."
            }
        }

        $nics += $nic

        Write-Host "NIC verified: $($nic.Name)"
        Write-Host "NIC ID: $($nic.Id)"
    }

    Write-Host "Pre-deletion checks passed."
    Write-Host "NICs identified: $($nics.Count)"

    # 6. Delete the VM resource
    Write-Host "Deleting VM: $VMName"

    Remove-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -Force `
        -ErrorAction Stop

    # 7. Verify VM deletion
    $remainingVM = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction SilentlyContinue

    if ($null -ne $remainingVM) {
        throw "VM still exists. NIC deletion will not proceed."
    }

    Write-Host "VM deletion verified."

    # 8. Delete captured NICs after VM deletion
    foreach ($oldNic in $nics) {

        $currentNic = $null

        # Allow Azure time to detach the NIC from the deleted VM
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $currentNic = Get-AzNetworkInterface `
                -ResourceGroupName $oldNic.ResourceGroupName `
                -Name $oldNic.Name `
                -ErrorAction SilentlyContinue

            if ($null -eq $currentNic) {
                break
            }

            if (-not $currentNic.VirtualMachine -or
                -not $currentNic.VirtualMachine.Id) {
                break
            }

            Write-Host "Waiting for NIC detachment ($attempt/12)..."
            Start-Sleep -Seconds 5
        }

        if ($null -eq $currentNic) {
            Write-Host "NIC already absent: $($oldNic.Name)"
            continue
        }

        if ($currentNic.VirtualMachine -and
            $currentNic.VirtualMachine.Id) {
            throw "NIC '$($currentNic.Name)' remains attached to a VM. NIC deletion stopped."
        }

        Write-Host "Deleting NIC: $($currentNic.Name)"

        Remove-AzNetworkInterface `
            -ResourceGroupName $currentNic.ResourceGroupName `
            -Name $currentNic.Name `
            -Force `
            -ErrorAction Stop

        # 9. Verify NIC deletion
        $remainingNic = Get-AzNetworkInterface `
            -ResourceGroupName $currentNic.ResourceGroupName `
            -Name $currentNic.Name `
            -ErrorAction SilentlyContinue

        if ($null -ne $remainingNic) {
            throw "NIC deletion could not be verified: $($currentNic.Name)"
        }

        Write-Host "NIC deletion verified: $($currentNic.Name)"
    }

    Write-Host "SUCCESS: VM and eligible attached NICs were deleted."
    Write-Host "Disks, Public IPs, NSGs and VNets were not explicitly deleted."
}
catch {
    Write-Error "Decommission failed: $($_.Exception.Message)"
    throw
}
