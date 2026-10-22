
$ErrorActionPreference = "Stop"

# ============================================================
# Azure VM Decommission - Email Notification
# Purpose:
# 1. Validate email configuration and request details
# 2. Send formatted HTML email through Gmail SMTP
# 3. Notify requester about PendingApproval status
#
# IMPORTANT:
# This script sends email only.
# It does NOT stop or delete the VM.
# ============================================================

# STEP 1: Read configuration

$smtpUsername    = $env:SMTP_USERNAME
$smtpAppPassword = $env:SMTP_APP_PASSWORD
$requester       = $env:REQUESTER
$requesterEmail  = $env:REQUESTER_EMAIL
$resourceGroup   = $env:RESOURCE_GROUP
$vmName          = $env:VM_NAME
$environment     = $env:VM_ENVIRONMENT
$subscriptionId  = $env:SUBSCRIPTION_ID
$requestId       = $env:REQUEST_ID
$jobStatus       = $env:JOB_STATUS

# STEP 2: Validate required values

$required = @{
    SMTP_USERNAME     = $smtpUsername
    SMTP_APP_PASSWORD = $smtpAppPassword
    REQUESTER_EMAIL   = $requesterEmail
    RESOURCE_GROUP    = $resourceGroup
    VM_NAME           = $vmName
    VM_ENVIRONMENT    = $environment
    SUBSCRIPTION_ID   = $subscriptionId
    REQUEST_ID        = $requestId
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Required configuration is missing: $($item.Key)"
    }
}

if ($environment -notin @("Dev", "Prod")) {
    throw "VM_ENVIRONMENT must be Dev or Prod."
}

if ($requesterEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "REQUESTER_EMAIL is not a valid email address."
}

if ([string]::IsNullOrWhiteSpace($requester)) {
    $requester = "Requester"
}

if ([string]::IsNullOrWhiteSpace($jobStatus)) {
    $jobStatus = "Unknown"
}

# STEP 3: Set waiting period

$waitingPeriodDays = switch ($environment) {
    "Dev"  { 7 }
    "Prod" { 11 }
}

# STEP 4: Prepare email details

$subject = "Azure VM Decommission Request - $vmName - Pending Approval"

# Encode user-provided values before inserting into HTML.
# This prevents special characters from breaking the email layout.

$encodedRequester      = [System.Net.WebUtility]::HtmlEncode($requester)
$encodedRequesterEmail = [System.Net.WebUtility]::HtmlEncode($requesterEmail)
$encodedVmName         = [System.Net.WebUtility]::HtmlEncode($vmName)
$encodedResourceGroup  = [System.Net.WebUtility]::HtmlEncode($resourceGroup)
$encodedEnvironment    = [System.Net.WebUtility]::HtmlEncode($environment)
$encodedSubscription   = [System.Net.WebUtility]::HtmlEncode($subscriptionId)
$encodedRequestId      = [System.Net.WebUtility]::HtmlEncode($requestId)
$encodedJobStatus      = [System.Net.WebUtility]::HtmlEncode($jobStatus)

$requestedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")

# STEP 5: Build formatted HTML email

$body = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body style="margin:0;padding:0;background-color:#f4f6f9;font-family:Arial,Helvetica,sans-serif;color:#243044;">

<div style="max-width:680px;margin:25px auto;background-color:#ffffff;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden;">

  <div style="background-color:#17365d;padding:25px 30px;color:#ffffff;">
    <h1 style="margin:0;font-size:23px;">Azure VM Decommission Request</h1>
    <p style="margin:10px 0 0;font-size:14px;color:#e5edf8;">
      Automated Cloud / DevOps notification
    </p>
  </div>

  <div style="padding:28px 30px;">
    <p style="font-size:15px;">Hello $encodedRequester,</p>

    <p style="font-size:14px;line-height:1.7;">
      Your Azure VM decommission request has been submitted and recorded.
      The request is awaiting the required review and approval process.
    </p>

    <div style="margin:22px 0;padding:15px;background-color:#fff7e6;border-left:4px solid #d99000;border-radius:4px;">
      <strong style="color:#805500;">Current status: Pending Approval</strong>
      <p style="margin:8px 0 0;font-size:13px;line-height:1.6;">
        This notification does not authorize deletion. No VM deletion is performed by the request or email notification script.
      </p>
    </div>

    <h2 style="font-size:17px;margin-top:25px;color:#17365d;">Request Details</h2>

    <table role="presentation" style="width:100%;border-collapse:collapse;font-size:13px;">
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;width:38%;"><strong>Request ID</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedRequestId</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>VM Name</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedVmName</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Resource Group</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedResourceGroup</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Environment</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedEnvironment</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Subscription ID</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedSubscription</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Requester Email</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedRequesterEmail</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Waiting Period</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$waitingPeriodDays days</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Workflow Run Status</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$encodedJobStatus</td>
      </tr>
      <tr>
        <td style="padding:11px;border:1px solid #e2e8f0;background:#f8fafc;"><strong>Email Generated (UTC)</strong></td>
        <td style="padding:11px;border:1px solid #e2e8f0;">$requestedAtUtc</td>
      </tr>
    </table>

    <h2 style="font-size:17px;margin-top:25px;color:#17365d;">What happens next?</h2>

    <ol style="font-size:14px;line-height:1.8;padding-left:22px;">
      <li>The request is recorded in Azure Storage Table.</li>
      <li>The required review and approval must be completed.</li>
      <li>The applicable waiting period must be verified before any authorized decommission action.</li>
    </ol>

    <p style="font-size:14px;line-height:1.7;">
      If the VM is still required, or you have concerns, please contact the Cloud / DevOps team and provide the Request ID above.
    </p>

    <p style="font-size:14px;line-height:1.7;margin-top:25px;">
      Regards,<br>
      <strong>Cloud / DevOps Team</strong><br>
      <span style="font-size:12px;color:#64748b;">Automated Azure VM Decommission Workflow</span>
    </p>
  </div>

  <div style="background-color:#f8fafc;border-top:1px solid #e2e8f0;padding:14px 30px;font-size:11px;color:#64748b;">
    This is an automated notification. Please do not reply directly unless your email process supports replies.
  </div>

</div>
</body>
</html>
"@

# STEP 6: Send email through Gmail SMTP

$securePassword = ConvertTo-SecureString `
    $smtpAppPassword `
    -AsPlainText `
    -Force

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
    $mail.IsBodyHtml = $true
    $mail.BodyEncoding = [System.Text.Encoding]::UTF8
    $mail.SubjectEncoding = [System.Text.Encoding]::UTF8

    $smtp = [System.Net.Mail.SmtpClient]::new(
        "smtp.gmail.com",
        587
    )

    $smtp.EnableSsl = $true
    $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials = $credential.GetNetworkCredential()
    $smtp.Timeout = 30000

    $smtp.Send($mail)

    Write-Host "============================================"
    Write-Host "EMAIL SENT SUCCESSFULLY"
    Write-Host "Recipient : $requesterEmail"
    Write-Host "VM        : $vmName"
    Write-Host "Request ID: $requestId"
    Write-Host "Status    : PendingApproval"
    Write-Host "============================================"
}
catch {
    Write-Error "Failed to send email notification: $($_.Exception.Message)"
    throw
}
finally {
    if ($smtp) {
        $smtp.Dispose()
    }

    if ($mail) {
        $mail.Dispose()
    }
}
