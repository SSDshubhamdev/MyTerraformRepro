[CmdletBinding()]
param(
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
    # Step 1: Require explicit confirmation
    if ($ConfirmDeletion -ne "yes") {
        throw "Deletion cancelled. Set ConfirmDeletion to yes only after approval."
    }

    # Step 2: Verify Azure PowerShell authentication
    $context = Get-AzContext

    if (-not $context -or -not $context.Subscription) {
        throw "Azure PowerShell is not authenticated. Check the Azure OIDC login step."
    }

    Write-Host "Authenticated Azure subscription: $($context.Subscription.Name)"
    Write-Host "Subscription ID: $($context.Subscription.Id)"
    Write-Host "Resource Group: $ResourceGroupName"
    Write-Host "VM Name: $VMName"

    # Step 3: Verify that the Resource Group exists
    $resourceGroup = Get-AzResourceGroup `
        -Name $ResourceGroupName `
        -ErrorAction Stop

    Write-Host "Resource Group verified: $($resourceGroup.ResourceGroupName)"

    # Step 4: Verify that the target VM exists
    $vm = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction Stop

    Write-Host "VM found: $($vm.Name)"
    Write-Host "Location: $($vm.Location)"
    Write-Host "Preparing to delete the VM resource..."

    # Step 5: Delete only the VM resource
    Remove-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -Force `
        -ErrorAction Stop

    Write-Host "VM deletion command completed."

    # Step 6: Verify deletion
    $remainingVM = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VMName `
        -ErrorAction SilentlyContinue

    if ($null -ne $remainingVM) {
        throw "VM '$VMName' still exists. Deletion could not be verified."
    }

    Write-Host "SUCCESS: VM '$VMName' deletion verified."
}
catch {
    Write-Error "VM decommission failed: $($_.Exception.Message)"
    throw
}
