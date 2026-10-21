
$ErrorActionPreference = "Stop"

# Read configuration from GitHub Actions secrets and workflow inputs
$smtpUsername = $env:SMTP_USERNAME
$smtpAppPassword = $env:SMTP_APP_PASSWORD
$requesterEmail = $env:REQUESTER_EMAIL
$resourceGroup = $env:RESOURCE_GROUP
$vmName = $env:VM_NAME
$environment = $env:VM_ENVIRONMENT
$subscriptionId = $env:SUBSCRIPTION_ID
$requestId = $env:REQUEST_ID

# Validate required values
$required = @{
    SMTP_USERNAME    = $smtpUsername
    SMTP_APP_PASSWORD = $smtpAppPassword
    REQUESTER_EMAIL  = $requesterEmail
    RESOURCE_GROUP   = $resourceGroup
    VM_NAME          = $vmName
    VM_ENVIRONMENT   = $environment
    SUBSCRIPTION_ID  = $subscriptionId
    REQUEST_ID       = $requestId
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($item.Value)) {
        throw "Required configuration is missing: $($item.Key)"
    }
}

if ($environment -notin @("Dev", "Prod")) {
    throw "VM_ENVIRONMENT must be Dev or Prod."
}

# Define waiting period
$waitingPeriodDays = switch ($environment) {
    "Dev" { 7 }
    "Prod" { 11 }
}

# Build notification email
$subject = "Azure VM Decommission Notice - $vmName"

$body = @"
Hello,

This is an automated notification that a decommission request has been
submitted for the following Azure virtual machine.

VM Name: $vmName
Resource Group: $resourceGroup
Environment: $environment
Subscription ID: $subscriptionId
Request ID: $requestId

Planned waiting period: $waitingPeriodDays days.

The VM is NOT being deleted by this notification step.
The decommission request is pending the configured review and approval
process. Any deletion must occur only after the required approval and
waiting period have been verified.

If this VM is required and should be retained, or if you have any
concerns, please contact the Cloud/DevOps team and quote the Request ID
above. The team will review your request and take the appropriate action.

Regards,
Cloud/DevOps Team
Automated Azure VM Decommission Workflow
"@

# Send email through Gmail SMTP
$securePassword = ConvertTo-SecureString $smtpAppPassword -AsPlainText -Force
$credential = [System.Management.Automation.PSCredential]::new(
    $smtpUsername,
    $securePassword
)

$mail = $null
$smtp = $null

try {
    $mail = [System.Net.Mail.MailMessage]::new()
    $mail.From = [System.Net.Mail.MailAddress]::new($smtpUsername)
    $mail.To.Add($requesterEmail)
    $mail.Subject = $subject
    $mail.Body = $body
    $mail.IsBodyHtml = $false

    $smtp = [System.Net.Mail.SmtpClient]::new("smtp.gmail.com", 587)
    $smtp.EnableSsl = $true
    $smtp.Credentials = $credential.GetNetworkCredential()

    $smtp.Send($mail)

    Write-Host "Email notification sent successfully to $requesterEmail."
    Write-Host "Request ID: $requestId"
    Write-Host "Waiting period: $waitingPeriodDays days"
}
finally {
    if ($smtp) { $smtp.Dispose() }
    if ($mail) { $mail.Dispose() }
}
