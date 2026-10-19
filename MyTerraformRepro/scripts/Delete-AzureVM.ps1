
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ConfirmDeletion
)

$ErrorActionPreference = "Stop"

# Safety: deletion must be explicitly approved
if ($ConfirmDeletion -ne "yes") {
    throw "Deletion cancelled. Set ConfirmDeletion to yes only after approval."
}

# Verify Azure login and subscription
$context = Get-AzContext

if (-not $context -or -not $context.Subscription) {
    throw "Azure PowerShell is not authenticated."
}

Write-Host "Subscription: $($context.Subscription.Name)"
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "VM Name: $VMName"

# Verify that the VM exists
$vm = Get-AzVM `
    -ResourceGroupName $ResourceGroupName `
    -Name $VMName `
    -ErrorAction Stop

Write-Host "VM found: $($vm.Name)"
Write-Host "Location: $($vm.Location)"
Write-Host "Starting VM deletion..."

# Delete only the VM resource
Remove-AzVM `
    -ResourceGroupName $ResourceGroupName `
    -Name $VMName `
    -Force `
    -ErrorAction Stop

Write-Host "VM deletion command completed."

# Verify that the VM resource no longer exists
$remainingVM = Get-AzVM `
    -ResourceGroupName $ResourceGroupName `
    -Name $VMName `
    -ErrorAction SilentlyContinue

if ($remainingVM) {
    throw "VM still exists. Please investigate the deletion status."
}

Write-Host "SUCCESS: VM resource deletion verified."
