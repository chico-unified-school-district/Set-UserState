#Requires -Version 5.0
<# 
.SYNOPSIS
.DESCRIPTION
 Set expiration dates for retired/terminated employee user accounts and moves expired accounts to disabled OU.
 Modifies Azure Licensing as needed.
 An email is sent to users warning them of the impending expiration.
.EXAMPLE
.INPUTS
.OUTPUTS
.NOTES
Special Thanks to June Castillote for helping me get MSOnline functioning properyl in Jenkins!
https://adamtheautomator.com/jenkins-powershll-64bit/
#>

[cmdletbinding()]
param (
 [Parameter(Mandatory = $True)]
 [Alias('DC')]
 [string]$DomainController,
 [Parameter(Mandatory = $True)]
 [Alias('ADCred')]
 [System.Management.Automation.PSCredential]$ActiveDirectoryCredential,
 [Parameter(Mandatory = $True)]
 [Alias('MSCred')]
 [System.Management.Automation.PSCredential]$MSOLCredentials,
 [Parameter(Mandatory = $True)]
 [Alias('DBServer')]
 [string]$DatabaseServer,
 [Parameter(Mandatory = $True)]
 [string]$Database,
 [Parameter(Mandatory = $True)]
 [Alias('DBCred')]
 [System.Management.Automation.PSCredential]$DatabaseCredential,
 [Parameter(Mandatory = $True)]
 [Alias('MailCred')]
 [System.Management.Automation.PSCredential]$EmailCredential,
 # Send the heads up email to another account
 [string]$BccAddress,
 [Alias('wi')]
 [SWITCH]$WhatIf
)
# $PSBoundParameters

Clear-Host # Clear Screen
Get-PSSession | Remove-PSSession

# Variables
$StaffOU = 'OU=Employees,OU=Users,OU=Domain_Root,DC=chico,DC=usd'
$retiredOU = 'OU=Resignation-Termination-Retired,OU=Disabled_User_Objects,DC=chico,DC=usd'

# Imported Functions
. .\lib\Add-Log.ps1
. .\lib\Invoke-SQLCommand.ps1
. .\lib\Set-PSCred.PS1

# Logging Info
if ( $WhatIf ) { Add-Log test "All Actions DISABLED" }

# MSOLservice
Invoke-Command -ComputerName ($ENV:COMPUTERNAME) -ScriptBlock {
 if (!(Get-module -ListAvailable -Name MSOnline)){
  Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -Confirm:$false
  Start-Sleep 5
  Install-Module -Name MSOnline -Scope CurrentUser -Force -Confirm:$false
 }
}

$msolSession = New-PSSession -ComputerName $ENV:COMPUTERNAME 
$msolCmdlets = 'Connect-MsolService','Get-MsolUser','Set-MsolUserLicense'
Import-PSSession -Session $msolSession -Module MSOnline -CommandName $msolCmdlets | Out-Null
Connect-MSOLService -Credential $MSOLCredentials

$a1License = 'chicousd:STANDARDWOFFPACK_FACULTY'

# AD Domain Controller Session
$adSession = New-PSSession -ComputerName $DomainController -Credential $ActiveDirectoryCredential
$adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Move-ADObject' , 'Search-ADAccount'
Import-PSSession -Session $adSession -Module 'ActiveDirectory' -CommandName $adCmdLets -AllowClobber | Out-Null

# DB Connection Variables
$dbParams = @{
 Server     = $DatabaseServer
 Database   = $Database
 Credential = $DatabaseCredential
 Query      = Get-Content -Path '.\sql\retired-terminated.sql' -Raw
}

# Processing
$dbResults = Invoke-SQLCommand @dbParams
"Employee DB Results: " + $dbResults.count

$employeeParams = @{
 filter     = {
  (employeeID -like "*") -and
  (mail -like "*@chicousd.org") -and
  (info -notlike "*Keep*Active*")
 }
 properties = 'employeeid', 'employeenumber', 'mail', 'AccountExpirationDate','LastLogonDate'
 searchBase = $StaffOU
}

$ADemployees = get-aduser @employeeParams | Where-Object {$_.distinguishedname -notlike "*OU=New Employee Accounts*"}
"AD Results`: " + $ADemployees.count

# Move Expired Accounts ============================================================
$expiredGracePeriod = (Get-Date).AddDays(-14)
$searchParams = @{
 AccountExpired = $True
 ResultPageSize = 20000
 UsersOnly      = $True
 SearchBase     = $StaffOU
}
$expiredAccounts = Search-ADAccount @searchParams | Where-Object {
 $_.AccountExpirationDate -lt $expiredGracePeriod -and
 $_.distinguishedname -notlike "*OU=New Employee Accounts*"
}

foreach ($user in $expiredAccounts) {
 Write-Debug ("Process {0}?" -f $user.samAccountName)
 Write-Verbose ("Processing {0}" -f $user.samAccountName)
 # Clear special attribute
 Set-ADUser -Identity $user.ObjectGUID -Clear extensionAttribute1 -Whatif:$WhatIf
 # Hide from Global Address List
 Set-ADUser -Identity $user.ObjectGUID -Replace @{msExchHideFromAddressLists = $true } -Whatif:$WhatIf
 # Move to Retired Org Unit
 Move-ADObject -Identity $user.ObjectGUID -TargetPath $retiredOU -Whatif:$WhatIf
 Add-Log action ('{0},Moved expired user account to Retired/Terminated OU.' -f $user.samAccountName ) $WhatIf
 $upn = $user.UserPrincipalName
 $msolData = Get-MsolUser -UserPrincipalName $upn
 foreach ( $license in ($msoldata.Licenses.AccountSkuId) ){
  Add-Log license ('{0}, Removing License: {1}' -f $upn, $license) $WhatIf
  if (!$WhatIf){ Set-MsolUserLicense -UserPrincipalName $upn -RemoveLicenses $license }
 }
}

Write-Host "Running Retired/Terminated search..."
$retiredTerminated = $ADemployees.ForEach( { if ($dbResults.empid -contains $_.employeeID) { $_ } })

# Check Retired/terminated ===========================================================
# Process Rows
foreach ( $user in $retiredTerminated ) {
 Write-Debug ("Process {0} {1}?" -f $user.samAccountName, $user.employeeID)
 Write-Verbose ("Processing {0} {1}" -f $user.samAccountName, $user.employeeID)
 $samid = $user.samAccountName
 $empId = $user.employeeId
 Write-Verbose "Processing $empId $samid - $($user.AccountExpirationDate)"
 if ( ($null -eq $user.AccountExpirationDate) -or ('' -eq $user.AccountExpirationDate)) {

  # Determine appropriate exit date ================================================
  # There are 2 date fields that can be used to record an employee's exit date
  $DateTerminationLastDay = ($dbResults.where( { $_.empID -eq $empId })).DateTerminationLastDay
  $DateTermination = ($dbResults.where( { $_.empID -eq $empId })).DateTerminationLastDay
  if ($DateTerminationLastDay -or $DateTermination){
   if ($DateTermination -ge $DateTerminationLastDay) { $lastDay = $DateTermination}
   else { $lastDay = $DateTerminationLastDay }
  }
  # Determine appropriate exit date ================================================
  
  # Check for existing DateTerminationLastDay
  if ( $lastDay -and ($lastDay.getType().name -ne 'DBNull') ) {
   # Set Account Expiration
   if ( (Get-Date $lastDay) -le (Get-Date) ){
    Add-Log warning "$samid,Employee Last day in the past,$lastDay"
    $expireDate = (Get-Date).AddDays(7)
   } else {
    $expireDate = Get-Date $lastDay
   }
  } else {
   Add-Log Warning "$empId,$samid,DateTerminationLastDay not set in Employee Database" $WhatIf
   # Check if the Account is out of use ==========================================
   $cutoffDate = (Get-Date).AddMonths(-6)
   # ================ STALE ACCOUNT SECTION =======================
   # LastPasswordChangeTimestamp
   if ($user.LastLogonDate -le $cutoffDate){
    $upn = $user.UserPrincipalName
    Add-Log stale ('{0},Account not used since {1}' -f $upn,$user.LastLogonDate) $WhatIf
    $msolData = Get-MsolUser -UserPrincipalName $upn
    foreach ( $license in ($msoldata.Licenses.AccountSkuId) ){
     Add-Log license ('{0}, Removing License: {1}' -f $upn, $license) $WhatIf
     if (!$WhatIf){ Set-MsolUserLicense -UserPrincipalName $upn -RemoveLicenses $license }
    }
    Add-Log license ('{0}, Adding Default License: {1}' -f $upn, $a1License) $WhatIf
    if (!$WhatIf){ Set-MsolUserLicense -UserPrincipalName $upn -AddLicenses $a1License }
    $expireDate = (Get-Date).AddDays(14)
    # Add-Log info "$empId,$samid,Setting AccountExpirationDate,$expireDate" $WhatIf
    # Set-ADUser -Identity $user.SamAccountName -AccountExpirationDate $expireDate -Whatif:$WhatIf
   } else { continue }
   # ================ STALE ACCOUNT SECTION =======================

  }
  Add-Log info "$empId,$samid,Setting AccountExpirationDate,$expireDate" $WhatIf
  Set-ADUser -Identity $user.SamAccountName -AccountExpirationDate $expireDate -Whatif:$WhatIf

  $headsUpMsg = Get-Content -Path '.\lib\HeadsUpEmail.txt' -Raw
  $headsUpHTML = $headsUpMsg -f $user.givenName, $user.samAccountName, ($expireDate | Out-String)

  $mailParams = @{
   To          = $user.mail
   From        = $EmailCredential.Username
   Subject     = 'CUSD Account Expiration'
   bodyAsHTML  = $true
   Body        = $headsUpHTML
   SMTPServer  = 'smtp.office365.com'
   Cred        = $EmailCredential
   UseSSL      = $True
   Port        = 587
  }
  if ($BccAddress) { $mailParams += @{Bcc = $BccAddress} }
  if ($WhatIf){
   $mailParams
  }
  else {
   Add-Log mail ('{0},CUSD Account Expiration email sent' -f $user.mail)
   Send-MailMessage @mailParams
  }
 }
 else {
  Write-Verbose "Expiration date already set for $empId $samid - $($user.AccountExpirationDate)" 
 }
} # End Process Rows

# Adjust Returning Users
$employeeParams = @{
 filter     = {
  (employeeID -like "*") -and
  (mail -like "*@chicousd.org") -and
  ( msExchHideFromAddressLists -eq $true )
 }
 properties = 'employeeid', 'employeenumber', 'mail', 'AccountExpirationDate', 'msExchHideFromAddressLists'
 searchBase = $StaffOU
}

$adEmployeeObjects = get-aduser @employeeParams | Where-Object {$_.employeeID -match "\d{4,}"}
Add-Log results ('AD employee object count: {0}' -f $adEmployeeObjects.count)
foreach ($obj in $adEmployeeObjects) {
 Set-ADUser -Identity $obj.ObjectGUID -clear msExchHideFromAddressLists -Whatif:$WhatIf
 Add-Log clear ('msExchHideFromAddressLists for {0}' -f $obj.samAccountName) -Whatif:$WhatIf
}

Write-Verbose "Tearing down sessions"
Get-PSSession | Remove-PSSession