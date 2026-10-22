
$ErrorActionPreference = "Stop"

Write-Host "======================================"
Write-Host " Azure VM Decommission Email"
Write-Host "======================================"

# Values passed by the GitHub Actions workflow
$requesterEmail = $env:REQUESTER_EMAIL
$requester      = $env:REQUESTER
$resourceGroup   = $env:RESOURCE_GROUP
$vmName         = $env:VM_NAME
$environment    = $env:VM_ENVIRONMENT
$subscriptionId  = $env:SUBSCRIPTION_ID
$requestId       = $env:REQUEST_ID

# GitHub Actions repository secrets
$smtpUsername    = $env:SMTP_USERNAME
$smtpAppPassword = $env:SMTP_APP_PASSWORD

$required = @{
    REQUESTER_EMAIL    = $requesterEmail
    REQUESTER          = $requester
    RESOURCE_GROUP     = $resourceGroup
    VM_NAME            = $vmName
    VM_ENVIRONMENT     = $environment
    SUBSCRIPTION_ID    = $subscriptionId
    REQUEST_ID         = $requestId
    SMTP_USERNAME      = $smtpUsername
    SMTP_APP_PASSWORD  = $smtpAppPassword
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Required environment variable is missing: $($item.Key)"
    }
}

# Remove spaces if the Gmail App Password was copied with spaces
$smtpAppPassword = $smtpAppPassword -replace '\s', ''

# Prepare safe HTML values
$safeRequester     = [System.Net.WebUtility]::HtmlEncode($requester)
$safeRequestId     = [System.Net.WebUtility]::HtmlEncode($requestId)
$safeVmName        = [System.Net.WebUtility]::HtmlEncode($vmName)
$safeResourceGroup = [System.Net.WebUtility]::HtmlEncode($resourceGroup)
$safeEnvironment   = [System.Net.WebUtility]::HtmlEncode($environment)
$safeSubscription  = [System.Net.WebUtility]::HtmlEncode($subscriptionId)
$safeRequesterEmail = [System.Net.WebUtility]::HtmlEncode($requesterEmail)

$subject = "Azure VM Decommission Request Submitted - $vmName"

$body = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body style="margin:0;padding:0;background-color:#f4f6f8;font-family:Arial,Helvetica,sans-serif;color:#202124;">
  <div style="max-width:680px;margin:24px auto;background:#ffffff;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden;">
    <div style="background:#17365d;color:#ffffff;padding:24px 28px;">
      <h2 style="margin:0;font-size:22px;">Azure VM Decommission Request</h2>
      <p style="margin:8px 0 0;font-size:14px;">Request submission confirmation</p>
    </div>

    <div style="padding:28px;">
      <p>Hello $safeRequester,</p>
      <p>Your Azure VM decommission request has been submitted successfully and recorded for approval.</p>

      <div style="background:#fff4d6;border-left:4px solid #d99a00;padding:14px 16px;margin:20px 0;">
        <strong>Current status:</strong> Pending Approval<br>
        <strong>Request ID:</strong> $safeRequestId
      </div>

      <h3 style="color:#17365d;margin-top:24px;">Request details</h3>
      <table style="width:100%;border-collapse:collapse;font-size:14px;">
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;width:38%;">VM Name</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeVmName</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Resource Group</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeResourceGroup</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Environment</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeEnvironment</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Subscription ID</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeSubscription</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Requested By</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeRequester</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Requester Email</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeRequesterEmail</td>
        </tr>
      </table>

      <p style="margin-top:24px;">No VM deletion is performed by the request-submission step. The request must go through the configured approval and decommission process.</p>

      <p>Regards,<br><strong>Azure Infrastructure Automation</strong></p>
    </div>

    <div style="background:#f4f6f8;padding:14px 28px;font-size:12px;color:#5f6368;">
      This is an automated notification. Please do not reply to this email.
    </div>
  </div>
</body>
</html>
"@

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

    $smtp = [System.Net.Mail.SmtpClient]::new("smtp.gmail.com", 587)
    $smtp.EnableSsl = $true
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials = [System.Net.NetworkCredential]::new(
        $smtpUsername,
        $smtpAppPassword
    )
    $smtp.Timeout = 30000

    Write-Host "Sending notification to $requesterEmail ..."
    $smtp.Send($mail)
    Write-Host "Email notification sent successfully."
}
catch {
    throw "Failed to send decommission request email. Details: $($_.Exception.Message)"
}
finally {
    if ($null -ne $mail) {
        $mail.Dispose()
    }
    if ($null -ne $smtp) {
        $smtp.Dispose()
    }
}
