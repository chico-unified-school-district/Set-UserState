#Requires -Version 5.0
<# 
.SYNOPSIS
.DESCRIPTION
 Set expiration dates for retired/terminated employee user accounts and moves expired accounts to disabled OU.
 An email is sent to users warning them of the impending expiration.
.EXAMPLE
.INPUTS
.OUTPUTS
.NOTES
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

# AD Domain Controller Session
$adSession = New-PSSession -ComputerName $DomainController -Credential $ActiveDirectoryCredential
$cmdLets = 'Get-ADUser', 'Set-ADUser', 'Move-ADObject' , 'Search-ADAccount'
Import-PSSession -Session $adSession -Module 'ActiveDirectory' -CommandName $cmdLets -AllowClobber | Out-Null

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
  (info -notlike "*Keep*Active*") -and
  (department -ne 380)
 }
 properties = 'employeeid', 'employeenumber', 'mail', 'AccountExpirationDate'
 searchBase = $StaffOU
}

$ADemployees = get-aduser @employeeParams | Where-Object {$_.distinguishedname -notlike "*OU=New Employee Accounts*"}
"AD Results`: " + $ADemployees.count

# Move Exppired Accounts ============================================================
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
 Set-ADUser -Identity $user.ObjectGUID -Clear extensionAttribute1 -Whatif:$WhatIf
 Set-ADUser -Identity $user.ObjectGUID -Replace @{msExchHideFromAddressLists = "TRUE" } -Whatif:$WhatIf
 Move-ADObject -Identity $user.ObjectGUID -TargetPath $retiredOU -Whatif:$WhatIf
 Add-Log action ('{0},Moved expired user account to Retired/Terminated OU.' -f $user.samAccountName ) $WhatIf
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
 # Write-Progress -Activity "Processing $([array]::IndexOf($retiredTerminated,$user))`/$($retiredTerminated.count)"
 if ( ($null -eq $user.AccountExpirationDate) -or ('' -eq $user.AccountExpirationDate)) {
  $lastDay = ($dbResults.where( { $_.empID -eq $empId })).DateTerminationLastDay
  # Check for existing DateTerminationLastDay
  if ( $lastDay -and ($lastDay.getType().name -ne 'DBNull') ) {
   # Set Account Expiration
   if ( (Get-Date $lastDay) -le (Get-Date) ){
    Add-Log warning "$samid,Employee Last day in the past,$lastDay"
    $expireDate = (Get-Date).AddDays(7)
   } else {
    $expireDate = Get-Date $lastDay
   }
  }
  else {
   Add-Log Warning "$empId,$samid,DateTerminationLastDay not set in Employee Database" $WhatIf
   continue
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

Write-Verbose "Tearing down sessions"
Get-PSSession | Remove-PSSession