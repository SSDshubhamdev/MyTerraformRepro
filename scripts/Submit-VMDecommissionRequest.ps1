
name: Azure VM Decommission - Request

on:
  workflow_dispatch:
    inputs:
      subscription_id:
        description: "Azure Subscription ID"
        required: true
        type: string
      resource_group:
        description: "Resource Group Name"
        required: true
        type: string
      vm_name:
        description: "Virtual Machine Name"
        required: true
        type: string
      environment:
        description: "Environment"
        required: true
        type: choice
        options:
          - Dev
          - Prod
      requester:
        description: "Request Raised By"
        required: true
        type: string

permissions:
  contents: read
  id-token: write

jobs:
  submit-decommission-request:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure login using OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ inputs.subscription_id }}
          enable-AzPSSession: true

      - name: Verify Azure Subscription Context
        uses: azure/powershell@v2
        with:
          azPSVersion: latest
          inlineScript: |
            $ErrorActionPreference = "Stop"

            $subscriptionId = "${{ inputs.subscription_id }}"
            $tenantId = "${{ secrets.AZURE_TENANT_ID }}"

            $context = Get-AzContext

            if ($null -eq $context -or
                $null -eq $context.Account) {
              throw "Azure PowerShell is not authenticated. Check OIDC login."
            }

            $subscription = Get-AzSubscription `
              -SubscriptionId $subscriptionId `
              -TenantId $tenantId `
              -ErrorAction Stop

            if ($null -eq $subscription) {
              throw "Subscription not found or not accessible to this identity."
            }

            Set-AzContext `
              -SubscriptionObject $subscription `
              -ErrorAction Stop | Out-Null

            $verifiedContext = Get-AzContext

            Write-Host "Authenticated Azure account successfully."
            Write-Host "Subscription ID: $($verifiedContext.Subscription.Id)"
            Write-Host "Tenant ID: $($verifiedContext.Tenant.Id)"

      - name: Validate VM and Save Request
        uses: azure/powershell@v2
        with:
          azPSVersion: latest
          inlineScript: ./scripts/Submit-VMDecommissionRequest.ps1
        env:
          SUBSCRIPTION_ID: ${{ inputs.subscription_id }}
          RESOURCE_GROUP: ${{ inputs.resource_group }}
          VM_NAME: ${{ inputs.vm_name }}
          VM_ENVIRONMENT: ${{ inputs.environment }}
          REQUESTER: ${{ inputs.requester }}
          AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          STORAGE_ACCOUNT: shubhamstorage11
          TABLE_NAME: VMDecommissionRequests
          DECOMMISSION_NOTIFICATION_WEBHOOK: ${{ secrets.DECOMMISSION_NOTIFICATION_WEBHOOK }}

      - name: Upload Request Summary
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: vm-decommission-request-summary
          path: decommission-request-summary.json
          if-no-files-found: ignore
          retention-days: 30
