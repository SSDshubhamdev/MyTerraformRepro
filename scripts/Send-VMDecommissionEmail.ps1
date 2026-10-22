
$ErrorActionPreference = "Stop"

$requesterEmail = $env:REQUESTER_EMAIL
$requester = $env:REQUESTER
$resourceGroup = $env:RESOURCE_GROUP
$vmName = $env:VM_NAME
$environment = $env:VM_ENVIRONMENT
$subscriptionId = $env:SUBSCRIPTION_ID
$requestId = $env:REQUEST_ID
$vmPowerState = $env:VM_POWER_STATE

$smtpUsername = $env:SMTP_USERNAME
$smtpAppPassword = $env:SMTP_APP_PASSWORD

$required = @{
    REQUESTER_EMAIL   = $requesterEmail
    REQUESTER         = $requester
    RESOURCE_GROUP    = $resourceGroup
    VM_NAME           = $vmName
    VM_ENVIRONMENT    = $environment
    SUBSCRIPTION_ID   = $subscriptionId
    REQUEST_ID        = $requestId
    VM_POWER_STATE    = $vmPowerState
    SMTP_USERNAME     = $smtpUsername
    SMTP_APP_PASSWORD = $smtpAppPassword
}

foreach ($item in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
        throw "Missing required environment variable: $($item.Key)"
    }
}

if ($vmPowerState -ne "VM deallocated") {
    throw "Email not sent because the VM is not confirmed as deallocated."
}

$smtpAppPassword = $smtpAppPassword -replace '\s', ''

$safeRequester = [System.Net.WebUtility]::HtmlEncode($requester)
$safeEmail = [System.Net.WebUtility]::HtmlEncode($requesterEmail)
$safeVm = [System.Net.WebUtility]::HtmlEncode($vmName)
$safeResourceGroup = [System.Net.WebUtility]::HtmlEncode($resourceGroup)
$safeEnvironment = [System.Net.WebUtility]::HtmlEncode($environment)
$safeSubscription = [System.Net.WebUtility]::HtmlEncode($subscriptionId)
$safeRequestId = [System.Net.WebUtility]::HtmlEncode($requestId)
$safePowerState = [System.Net.WebUtility]::HtmlEncode($vmPowerState)
$completedAt = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")

$subject = "Azure VM Deallocated Successfully - $vmName"

$body = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body style="margin:0;padding:20px;background:#f3f5f7;font-family:Arial,Helvetica,sans-serif;color:#202124;">
  <div style="max-width:680px;margin:auto;background:#ffffff;border:1px solid #dfe3e8;border-radius:8px;overflow:hidden;">
    <div style="background:#17365d;color:#ffffff;padding:24px;">
      <h2 style="margin:0;">Azure VM Decommission Notification</h2>
      <p style="margin:8px 0 0;">VM stop operation completed</p>
    </div>

    <div style="padding:26px;">
      <p>Hello $safeRequester,</p>
      <p>The Azure VM deallocation operation has completed, and the VM power state has been verified successfully.</p>

      <div style="background:#e7f5e9;border-left:4px solid #27833e;padding:15px;margin:20px 0;">
        <strong>Verified VM Power State:</strong> $safePowerState<br>
        <strong>VM Deleted:</strong> No
      </div>

      <h3 style="color:#17365d;">Request Details</h3>
      <table style="width:100%;border-collapse:collapse;font-size:14px;">
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Request ID</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeRequestId</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">VM Name</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeVm</td>
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
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Requester Email</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$safeEmail</td>
        </tr>
        <tr>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;font-weight:bold;">Completed At</td>
          <td style="padding:10px;border-bottom:1px solid #e5e7eb;">$completedAt</td>
        </tr>
      </table>

      <p style="margin-top:22px;">The VM has not been deleted. Disks and other attached Azure resources may continue to incur charges.</p>
      <p>Regards,<br><strong>Azure Infrastructure Automation</strong></p>
    </div>

    <div style="background:#f3f5f7;padding:14px 26px;color:#5f6368;font-size:12px;">
      Automated notification. Please do not reply to this email.
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

    Write-Host "Sending email to $requesterEmail ..."
    $smtp.Send($mail)
    Write-Host "Customer notification sent successfully."
}
catch {
    throw "VM was deallocated, but the email could not be sent. Details: $($_.Exception.Message)"
}
finally {
    if ($null -ne $mail) {
        $mail.Dispose()
    }

    if ($null -ne $smtp) {
        $smtp.Dispose()
    }
}
