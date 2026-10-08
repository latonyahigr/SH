#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param([string]$Directory = 'C:\PasswordRotation')
$ErrorActionPreference = 'Stop'
$TargetUser = 'Administrator'
$RecoveryUser = 'RDP-Recovery'
$TaskName = 'Daily-Administrator-Password-Rotation'
if (-not [Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell.' }
Import-Module Microsoft.PowerShell.LocalAccounts
Import-Module ScheduledTasks
$target = Get-LocalUser -Name $TargetUser
if (-not $target.Enabled) { throw 'Administrator is disabled. Enable the intended account explicitly before deployment.' }
Set-TimeZone -Id 'China Standard Time'
$Directory = [IO.Path]::GetFullPath($Directory)
if ($Directory.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Directory).TrimEnd('\')) { throw 'Use a dedicated directory, never a drive root.' }
New-Item -ItemType Directory -Path $Directory -Force | Out-Null
# Reject links: do not redirect password files to another location.
if ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Directory must not be a reparse point.' }
foreach ($item in Get-ChildItem -LiteralPath $Directory -Force -Recurse) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Remove reparse points from the rotation directory.' }
}
# SID-based ACL works on localized Windows; replace inherited and explicit rules.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544')
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]$sid, 'FullControl',
        'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $Directory -AclObject $acl
foreach ($item in Get-ChildItem -LiteralPath $Directory -Force -Recurse) {
    if ($item.PSIsContainer) { $childAcl = New-Object System.Security.AccessControl.DirectorySecurity }
    else { $childAcl = New-Object System.Security.AccessControl.FileSecurity }
    $childAcl.SetAccessRuleProtection($false, $false)
    $childAcl.SetOwner([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    Set-Acl -LiteralPath $item.FullName -AclObject $childAcl
}
function New-StrongPassword([int]$Length) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ','abcdefghijkmnopqrstuvwxyz','23456789','!@#$%*-_=+?')
    $alphabet = $sets -join ''
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $builder = New-Object Text.StringBuilder
            $byte = New-Object byte[] 1
            while ($builder.Length -lt $Length) {
                $rng.GetBytes($byte)
                $limit = 256 - (256 % $alphabet.Length)
                if ($byte[0] -lt $limit) { [void]$builder.Append($alphabet[$byte[0] % $alphabet.Length]) }
            }
            $password = $builder.ToString()
            $valid = $true
            foreach ($set in $sets) {
                if ($password.IndexOfAny($set.ToCharArray()) -lt 0) { $valid = $false }
            }
        } until ($valid)
        return $password
    } finally { $rng.Dispose() }
}
$passwordPath = Join-Path $Directory 'passwords.txt'
$startPath = Join-Path $Directory 'start-date.txt'
if (Test-Path -LiteralPath $passwordPath) {
    $passwords = @(Get-Content -LiteralPath $passwordPath)
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($password in $passwords) { [void]$unique.Add($password) }
    if ($passwords.Count -ne 365 -or $unique.Count -ne 365) { throw 'Existing passwords.txt must contain 365 distinct lines. It was not overwritten.' }
    if (-not (Test-Path -LiteralPath $startPath)) { throw 'Existing password book has no start-date.txt. Restore its original start date; do not reset the schedule.' }
} else {
    if (Test-Path -LiteralPath $startPath) { throw 'start-date.txt exists but passwords.txt is missing. Restore the original password book.' }
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $passwords = @(
        while ($unique.Count -lt 365) {
            $password = New-StrongPassword 24
            if ($unique.Add($password)) { $password }
        }
    )
    $now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
    $first = $now.Date.AddHours(4)
    if ($now -ge $first) { $first = $first.AddDays(1) }
    # Store anchor first: interrupted deployment cannot silently regenerate the book.
    $first.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) | Set-Content -LiteralPath $startPath -Encoding ASCII
    $passwords | Set-Content -LiteralPath $passwordPath -Encoding ASCII
}
$startDate = [DateTime]::ParseExact((Get-Content -LiteralPath $startPath -Raw).Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$recovery = Get-LocalUser | Where-Object Name -EQ $RecoveryUser
$admins = Get-LocalGroup -SID 'S-1-5-32-544'
if (-not $recovery) {
    $recoveryPassword = New-StrongPassword 32
    # Write before account creation so a later failure cannot lose the password.
    $recoveryPassword | Set-Content -LiteralPath (Join-Path $Directory 'RECOVERY-PASSWORD.txt') -Encoding ASCII
    $recovery = New-LocalUser -Name $RecoveryUser -Password (ConvertTo-SecureString $recoveryPassword -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Emergency recovery; excluded from daily rotation'
    Write-Host "Recovery login: .\$RecoveryUser"
    Write-Host "SAVE THIS RECOVERY PASSWORD NOW: $recoveryPassword"
    Write-Warning 'After saving securely, delete RECOVERY-PASSWORD.txt. Never upload it.'
} else {
    if (-not $recovery.Enabled -or $recovery.PasswordExpires -or $recovery.AccountExpires) {
        throw 'Existing Recovery account is disabled or expires. Repair it explicitly; its password was not changed.'
    }
    Write-Host 'Existing Recovery password preserved.'
}
if (-not (Get-LocalGroupMember -Group $admins.Name | Where-Object { $_.SID -eq $recovery.SID })) {
    Add-LocalGroupMember -Group $admins.Name -Member $recovery
}
@(
    for ($i = 0; $i -lt 365; $i++) {
        [pscustomobject]@{ Day = $i + 1; Date = $startDate.AddDays($i).ToString('yyyy-MM-dd'); Password = $passwords[$i] }
    }
) | Export-Csv -LiteralPath (Join-Path $Directory 'PasswordBook-365.csv') -NoTypeInformation -Encoding UTF8
$rotate = @'
#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$Directory = $PSScriptRoot
$logPath = Join-Path $Directory 'rotation.log'
function Write-RotationLog([string]$Status, [string]$Message) {
    $stamp = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time').ToString('yyyy-MM-dd HH:mm:ss')
    "$stamp $Status $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8
}
try {
    Import-Module Microsoft.PowerShell.LocalAccounts
    $start = [DateTime]::ParseExact((Get-Content -LiteralPath (Join-Path $Directory 'start-date.txt') -Raw).Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
    $passwordDate = $now.AddHours(-4).Date
    $elapsed = ($passwordDate - $start.Date).Days
    $passwords = @(Get-Content -LiteralPath (Join-Path $Directory 'passwords.txt'))
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($password in $passwords) { [void]$unique.Add($password) }
    if ($passwords.Count -ne 365 -or $unique.Count -ne 365) { throw 'Invalid password book' }
    $target = Get-LocalUser -Name 'Administrator'
    if (-not $target.Enabled) { throw 'Administrator is disabled' }
    if ($CheckOnly) {
        $mappedDay = $null
        if ($elapsed -ge 0) { $mappedDay = ($elapsed % 365) + 1 }
        [pscustomobject]@{ Mode = 'CHECK-ONLY'; BeijingTime = $now; Day1 = $start.AddHours(4); Day = $mappedDay; PasswordCount = $passwords.Count; UniqueCount = $unique.Count; TargetEnabled = $target.Enabled }
        exit 0
    }
    if ($elapsed -lt 0) {
        Write-RotationLog 'SKIPPED' 'Before Day 1; password unchanged'
        exit 0
    }
    $day = ($elapsed % 365) + 1
    # Same date always maps to the same password; no incrementing counter.
    Set-LocalUser -Name 'Administrator' -Password (ConvertTo-SecureString $passwords[$day - 1] -AsPlainText -Force)
    Write-RotationLog 'SUCCESS' "User=Administrator Day=$day PasswordDate=$($passwordDate.ToString('yyyy-MM-dd'))"
} catch {
    # Do not log exception text: custom providers may include sensitive values.
    if ($CheckOnly) {
        Write-Error "Check failed; ErrorType=$($_.Exception.GetType().FullName)" -ErrorAction Continue
        exit 1
    }
    Write-RotationLog 'FAILED' "Password rotation failed; ErrorType=$($_.Exception.GetType().FullName)"
    exit 1
}
'@
$rotatePath = Join-Path $Directory 'rotate.ps1'
$rotate | Set-Content -LiteralPath $rotatePath -Encoding UTF8
$logPath = Join-Path $Directory 'rotation.log'
if (-not (Test-Path -LiteralPath $logPath)) { New-Item -ItemType File -Path $logPath | Out-Null }
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$rotatePath`"" -WorkingDirectory $Directory
$trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(4)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Deployed: $TaskName | SYSTEM / Highest | Beijing 04:00 daily"
Write-Host "Directory: $Directory | Day 1: $($startDate.ToString('yyyy-MM-dd')) 04:00 UTC+8"
Write-Host '365 passwords preserved across reinstall; cycle repeats after Day 365.'
Write-Host 'Administrator password is not changed during installation. Recovery is excluded.'
Write-Host "Read-only check: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$rotatePath`" -CheckOnly"
Write-Warning 'Save the password book and Recovery password in a secure vault. Delete RECOVERY-PASSWORD.txt after saving. Never commit real passwords, CSV books, or Recovery credentials to GitHub.'
