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
 [Alias('License')]
 [string]$DefaultLicenseSkuID,
 [Parameter(Mandatory = $True)]
 [string]$EscapeServer,
 [Parameter(Mandatory = $True)]
 [string]$EscapeDatabase,
 [Parameter(Mandatory = $True)]
 [System.Management.Automation.PSCredential]$EscapeCredential,
 [Parameter(Mandatory = $True)]
 [string]$SISServer,
 [Parameter(Mandatory = $True)]
 [string]$SISDatabase,
 [Parameter(Mandatory = $True)]
 [System.Management.Automation.PSCredential]$SISCredential,
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
# $retiredOU = 'OU=Resignation-Termination-Retired,OU=Disabled_User_Objects,DC=chico,DC=usd'

# Imported Functions
. .\lib\Add-Log.ps1
. .\lib\Invoke-SQLCommand.ps1
. .\lib\Set-PSCred.PS1

# Logging Info
if ( $WhatIf ) { Add-Log test "All Actions DISABLED" }

# MSOLservice
Invoke-Command -ComputerName ($ENV:COMPUTERNAME) -ScriptBlock {
 if (!(Get-module -ListAvailable -Name MSOnline)) {
  Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -Confirm:$false
  Start-Sleep 5
  Install-Module -Name MSOnline -Scope CurrentUser -Force -Confirm:$false
 }
}

$msolSession = New-PSSession -ComputerName $ENV:COMPUTERNAME
$msolCmdlets = 'Connect-MsolService', 'Get-MsolUser', 'Set-MsolUserLicense', 'Get-MsolAccountSku'
Import-PSSession -Session $msolSession -Module MSOnline -CommandName $msolCmdlets -AllowClobber | Out-Null
Connect-MSOLService -Credential $MSOLCredentials

# AD Domain Controller Session
$adSession = New-PSSession -ComputerName $DomainController -Credential $ActiveDirectoryCredential
$adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Move-ADObject' , 'Search-ADAccount'
Import-PSSession -Session $adSession -Module 'ActiveDirectory' -CommandName $adCmdLets -AllowClobber | Out-Null

$EscapeParams = @{
 Server     = $EscapeServer
 Database   = $EscapeDatabase
 Credential = $EscapeCredential
 Query      = Get-Content -Path '.\sql\retired-terminated.sql' -Raw
}

$SISParams = @{
 Server     = $SISServer
 Database   = $SISDatabase
 Credential = $SISCredential
}

function setSISStatus ($id, $sam) {
 $sisCheckQuery = "SELECT ID FROM STF WHERE ID = {0}" -f $id
 Write-Verbose $sisCheckQuery
 $idCheck = Invoke-SQLCommand @SISParams -Query $sisCheckQuery
 if ($idCheck) {
  $updateSTF = "UPDATE STF SET tg = `'i`' WHERE id = {0}" -f $id
  Invoke-SQLCommand @SISParams -Query $updateSTF -Whatif:$WhatIf
  Add-Log sisupdate ('SET {0} {1} to inactive in {0} STF Table' -f $id, $sam, $SISDatabase) -Whatif:$WhatIf
 }
 else {
  Add-Log sisinfo ('ID {0} not found in {1} for {2}. No changes were made to STF Table.' -f $id, $SISDatabase, $sam)
 }
}

# Processing
$escapeDBResults = Invoke-SQLCommand @EscapeParams
"Employee DB Results: " + $escapeDBResults.count

$employeeParams = @{
 filter     = {
  (employeeID -like "*") -and
  (mail -like "*@chicousd.org")
 }
 properties = 'employeeid', 'employeenumber', 'mail', 'AccountExpirationDate', 'LastLogonDate', 'info'
 searchBase = $StaffOU
}

# Exclude new employee accounts and accounts with 'keep' and 'active' strings in the 'info' (notes) attribute
$ADemployees = get-aduser @employeeParams | Where-Object {
 ( ($_.info -notmatch 'keep') -and ($_.info -notmatch 'active') )
}
# $ADemployees = get-aduser @employeeParams | Where-Object {
#  ( $_.distinguishedname -notlike "*OU=New Employee Accounts*" ) -and
#  ( ($_.info -notmatch 'keep') -and ($_.info -notmatch 'active') )
# }
"AD Results`: " + $ADemployees.count

# Process Expired Accounts ============================================================
$expiredGracePeriod = (Get-Date).AddDays(-14)
$searchParams = @{
 AccountExpired = $True
 ResultPageSize = 20000
 UsersOnly      = $True
 SearchBase     = $StaffOU
}
$expiredAccounts = Search-ADAccount @searchParams | Where-Object {
 ($_.AccountExpirationDate -lt $expiredGracePeriod) -and
 ($_.Enabled -ne $false)
}
# $expiredAccounts = Search-ADAccount @searchParams | Where-Object {
#  $_.AccountExpirationDate -lt $expiredGracePeriod -and
#  $_.distinguishedname -notlike "*OU=New Employee Accounts*"
# }

function Get-RandomCharacters($length, $characters) {
 $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
 $private:ofs = ''
 return [String]$characters[$random]
}
function New-RandomPw {
 $chars = 'ABCDEFGHKLMNOPRSTUVWXYZabcdefghiklmnoprstuvwxyz1234567890!$#%&*@'
 do { $pw = (Get-RandomCharacters -length 16 -characters $chars) }
 until ($pw -match '[A-Za-z\d!$#%&*@]') # Make sure minimum criteria met using regex p@ttern.
 $pw # Output random password
}
function processExpired {
 begin { Write-Host 'Processing already expired accounts' -Fore Blue }
 process {
  Write-Verbose ($_ | OUt-String )
  Write-Debug ("Process {0}?" -f $_.samAccountName)
  Write-Verbose ("Processing {0}" -f $_.samAccountName)
  # Disable Account
  Set-ADuser -Identity $_.ObjectGUID -Enabled:$false -Confirm:$false -WhatIf:$WhatIf
  # Clear special attribute
  Set-ADUser -Identity $_.ObjectGUID -Clear extensionAttribute1 -Whatif:$WhatIf
  # Hide from Global Address List
  Set-ADUser -Identity $_.ObjectGUID -Replace @{msExchHideFromAddressLists = $true } -Whatif:$WhatIf
  # Update Password
  Add-Log udpate ('{0}, AD account password set to random' -f $_.samAccountName) -Whatif:$WhatIf
  $randomPW = ConvertTo-SecureString -String (New-RandomPw) -AsPlainText -Force
  Set-ADAccountPassword -Identity $_.ObjectGUID -NewPassword $randomPW -Confirm:$false -WhatIf:$WhatIf
  # Move to Retired Org Unit
  # TODO This OU structure needs revisting due to sync issues with moved accounts.
  # Move-ADObject -Identity $_.ObjectGUID -TargetPath $retiredOU -Whatif:$WhatIf
  # Add-Log action ('{0},Moved expired user account to Retired/Terminated OU.' -f $_.samAccountName ) $WhatIf

  $userAccount = Get-ADuser -Identity $_.ObjectGUID -Properties employeeID
  setSISStatus -id $userAccount.employeeId -sam $userAccount.samAccountName

  $upn = $_.UserPrincipalName
  $msolData = Get-MsolUser -UserPrincipalName $upn
  foreach ( $license in ($msoldata.Licenses.AccountSkuId) ) {
   Add-Log license ('{0}, Removing License: {1}' -f $upn, $license) $WhatIf
   if (!$WhatIf) { Set-MsolUserLicense -UserPrincipalName $upn -RemoveLicenses $license }
  }
 }
 End { Write-Host 'End Processing already expired accounts' -Fore Blue }
}

# TODO Code needs to be reorganized
$expiredAccounts | processExpired

# Check Retired/terminated ===========================================================
$accountSkuIds = (Get-MsolAccountSku).AccountSkuId
function processExpiring {
 begin { Write-Host 'Processing soon-to-be expiring accounts' -Fore Green }
 process {
  if ($_.Enabled -eq $false) { continue }
  # ($_ | Out-String)
  Write-Debug ("Process? [{0}] [{1}] {2}?" -f $_.employeeID, $_.samAccountName, $_.AccountExpirationDate)
  Write-Verbose ("Processing [{0}] [{1}] [{2}]" -f $_.employeeID, $_.samAccountName, $_.AccountExpirationDate)
  $samid = $_.samAccountName
  $empId = $_.employeeId

  # Write-Verbose "Processing $empId $samid - $($_.AccountExpirationDate)"

  if ( ($null -eq $_.AccountExpirationDate) -or ('' -eq $_.AccountExpirationDate)) {
   # Begin Expire Date Anchor

   # Beside an AccountExpirationDate value already being present,
   # there are 2 EscapeOnline date fields that can be used to record an employee's exit date
   # Determine appropriate exit date ================================================
   $dateTerm0 = $_.AccountExpirationDate
   $dateTerm1 = ($escapeDBResults.where( { $_.empID -eq $empId })).DateTerminationLastDay
   $dateTerm2 = ($escapeDBResults.where( { $_.empID -eq $empId })).DateTermination

   if ( $dateTerm0 ) { $lastDay = $dateTerm0 }
   elseif ( [string]$dateTerm2 -as [DateTime] ) { $lastDay = $dateTerm2 }
   elseif ( [string]$dateTerm1 -as [DateTime] ) { $lastDay = $dateTerm1 }

   # Set Account Expiration
   if ( (Get-Date $lastDay) -le (Get-Date) ) {
    Add-Log info "$samid,Employee Last day in the past,$lastDay"
    $expireDate = (Get-Date).AddDays(7)
   }
   else { $expireDate = Get-Date $lastDay }

   Add-Log info "$empId,$samid,Setting AccountExpirationDate,$expireDate" $WhatIf
   Set-ADUser -Identity $_.SamAccountName -AccountExpirationDate $expireDate -Whatif:$WhatIf

   $headsUpMsg = Get-Content -Path '.\lib\HeadsUpEmail.txt' -Raw
   $headsUpHTML = $headsUpMsg -f $_.givenName, $_.samAccountName, ($expireDate | Out-String)

   $mailParams = @{
    To         = $_.mail
    From       = $EmailCredential.Username
    Subject    = 'CUSD Account Expiration'
    bodyAsHTML = $true
    Body       = $headsUpHTML
    SMTPServer = 'smtp.office365.com'
    Cred       = $EmailCredential
    UseSSL     = $True
    Port       = 587
   }

   if ($BccAddress) { $mailParams += @{Bcc = $BccAddress } }

   Add-Log action ('{0},CUSD Account Expiration email sent' -f $_.mail) $WhatIf
   if (!$WhatIf) { Send-MailMessage @mailParams }
  } # End Expire Date Anchor
  else {
   Write-Verbose ('{0} {1} {2} Expiration date already set' -f $empId, $samid, $_.AccountExpirationDate)
  }

 }
 end { Write-Host 'End Processing soon-to-be expiring accounts' -Fore Green }
} # End processExpriring function


Write-Host "Running Escape Retired/Terminated search..."
$escapeStaffExpiring = $ADemployees.ForEach(
 {
  if ($escapeDBResults.empid -contains $_.employeeID) {
   if ($_.Enabled -eq $true) {
    $_
   }
  }
 })
Write-Host "Running Non-Escape Staff search..."
$otherStafExpiring = $ADemployees.Where(
 {
   ($_.AccountExpirationDate -lt ((Get-Date).AddDays(14))) -and
  ($null -ne $_.AccountExpirationDate) -and
 ($_.Enabled -ne $false)
 }
)

# Process Expiring staff for Expired
# $escapeStaffExpiring | Select-Object samAccountName, employeeId
# $otherStafExpiring  | Select-Object samAccountName, employeeId
$escapeStaffExpiring | processExpiring
$otherStafExpiring | processExpiring
# TODO For testing?

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

# # TODO fix this logic or remove
# $todaysDate = [int](Get-Date -f yyyymmdd)
# $adEmployeeObjects = Get-ADUser @employeeParams | Where-Object {
#  $expiredate = [int](Get-Date $_.AccountExpirationDate -f yyyymmdd)
#  ($null -eq $_.AccountExpirationDate) -or ($expiredate -gt $todaysDate)
# }
# Add-Log results ('AD employee object count: {0}' -f $adEmployeeObjects.count)
# foreach ($obj in $adEmployeeObjects) {
#  Set-ADUser -Identity $obj.ObjectGUID -clear msExchHideFromAddressLists -Whatif:$WhatIf
#  Add-Log clear ('msExchHideFromAddressLists for {0}' -f $obj.samAccountName) -Whatif:$WhatIf
# }

Write-Verbose "Tearing down sessions"
Get-PSSession | Remove-PSSession