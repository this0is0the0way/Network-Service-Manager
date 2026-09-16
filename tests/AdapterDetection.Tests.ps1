#requires -Version 5.1
# Offline regression checks: load function definitions only, never Start-Beskar.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'NetworkManager.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw ($errors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

$script:Properties = @()
$script:ReadFailure = $false
$script:Writes = 0
$script:Saved = $null
$script:AdapterName = 'Test Ethernet'
$script:AdapterGuid = 'original-guid'
$script:AdapterCapability = $null
$script:VlanProperty = $null
$script:Adapters = @([pscustomobject]@{ Name = $script:AdapterName; InterfaceGuid = $script:AdapterGuid })

# Every external dependency used below is replaced, including disk writes.
function Get-NetAdapterAdvancedProperty {
    param($Name, $RegistryKeyword, [switch]$AllProperties, $ErrorAction)
    if ($script:ReadFailure) { throw 'Simulated driver read failure' }
    if ($RegistryKeyword) {
        return @($script:Properties | Where-Object { $_.RegistryKeyword -eq $RegistryKeyword })
    }
    return $script:Properties
}
function Get-NetAdapter { param([switch]$Physical, $ErrorAction) return $script:Adapters }
function Get-AdapterDriverMetadata {
    param($Name)
    return [pscustomobject]@{
        MatchingDeviceId = 'test-device'; DriverVersion = 'test-version'
        ProviderName = 'test-provider'; InterfaceDescription = 'test-description'
    }
}
function Save-DetectedAdapterCapability { param($Capability) $script:Saved = $Capability }
function Find-SavedAdapterCapability { throw 'Detection must not trust cached capabilities' }
function Set-NetAdapterAdvancedProperty {
    param($Name, $RegistryKeyword, $RegistryValue, [switch]$NoRestart, $ErrorAction)
    $script:Writes++
    ($script:Properties | Where-Object { $_.RegistryKeyword -eq $RegistryKeyword }).RegistryValue = @($RegistryValue)
}
function Remove-NetAdapterAdvancedProperty {
    param($Name, $RegistryKeyword, [switch]$NoRestart, $Confirm, $ErrorAction)
    $script:Writes++
    ($script:Properties | Where-Object { $_.RegistryKeyword -eq $RegistryKeyword }).RegistryValue = $null
}
function Start-Sleep { param($Milliseconds, $Seconds) }
function Write-OperationLog { param($Action, $Result, $Details) }
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    Assert-True $caught 'Expected operation to fail'
}
function New-DriverProperty {
    param($Keyword, $DisplayName, $Value, [bool]$Optional = $false, $Default = $null)
    return [pscustomobject]@{
        RegistryKeyword = $Keyword; DisplayName = $DisplayName; RegistryValue = $Value
        Optional = $Optional; DefaultRegistryValue = $Default
    }
}

# Intel: a tagging switch is never a VLAN ID; a hidden name is unconfirmed.
$priority = New-DriverProperty '*PriorityVLANTag' 'Packet Priority & VLAN' @('3')
$intel = New-DriverProperty 'IntelANSVlanID' '' $null
$script:Properties = @($priority, $intel)
Update-SelectedAdapterCapability
Assert-True (-not $script:AdapterCapability.SupportsVlan) 'Hidden Intel property accepted as supported'
Assert-True ($script:AdapterCapability.VlanKeyword -eq 'IntelANSVlanID') 'Diagnostic candidate missing'
Assert-True (@(Get-VlanCandidateProperties -Name $script:AdapterName).Count -eq 1) 'Priority switch became a candidate'
Assert-Throws { Set-RequestedVlan -Value 123 } 'VLAN ID'
Set-RequestedVlan -Value $null
Assert-True ($script:Writes -eq 0) 'Empty hidden property or priority switch was modified'

# An unknown nonempty value must not be silently ignored or reset to zero.
$intel.RegistryValue = @('123')
Assert-Throws { Set-RequestedVlan -Value $null } 'IntelANSVlanID'
Assert-True ($script:Writes -eq 0) 'Unknown nonempty VLAN was changed'

# ASIX: remove optional VLAN, then apply another VLAN with the same keyword.
$script:Properties = @(New-DriverProperty 'VLAN_ID' 'VLAN ID' @('1217') $true)
Update-SelectedAdapterCapability
Assert-True $script:AdapterCapability.SupportsVlan 'ASIX not detected'
Assert-True ($script:AdapterCapability.DisableMethod -eq 'RemoveProperty') 'Optional reset lost'
Set-RequestedVlan -Value $null
Assert-True (Test-VlanIsDisabled) 'ASIX VLAN not removed'
Set-RequestedVlan -Value 1212
Assert-True ((Get-CurrentVlanRawValue) -eq '1212') 'ASIX VLAN not set'

# A driver-declared default is reevaluated; no saved Unknown can override it.
$script:Properties = @(New-DriverProperty 'RegVlanID' 'VLAN ID' @('200') $false @('0'))
Update-SelectedAdapterCapability
Assert-True ($script:AdapterCapability.DisableMethod -eq 'SetValue') 'Fresh default ignored'
Set-RequestedVlan -Value $null
Assert-True ((Get-CurrentVlanRawValue) -eq '0') 'Declared disabled value not applied'

# A previously supported keyword disappearing must invalidate old capability.
$script:Properties = @($priority)
Update-SelectedAdapterCapability
Assert-True (-not $script:AdapterCapability.SupportsVlan) 'Stale capability survived rescan'
Assert-True ($null -eq $script:AdapterCapability.VlanKeyword) 'Stale keyword survived rescan'
Set-RequestedVlan -Value $null

# Read errors cannot be interpreted as absence of VLAN or use stale state.
$script:ReadFailure = $true
Assert-Throws { Update-SelectedAdapterCapability } 'Simulated driver read failure'
Assert-True ($null -eq $script:AdapterCapability) 'Stale state survived failed scan'
Assert-Throws { Test-VlanIsDisabled } 'Simulated driver read failure'
$script:ReadFailure = $false

# Disappearance and replacement under the same alias require re-selection.
$script:Adapters = @()
Assert-Throws { Update-SelectedAdapterCapability } 'adapter'
$script:Adapters = @([pscustomobject]@{ Name = $script:AdapterName; InterfaceGuid = 'replacement-guid' })
Assert-Throws { Update-SelectedAdapterCapability } 'adapter'

# Optional PingTarget omitted by the profile wizard is valid under StrictMode.
$EnablePing = $true
Test-ProfileConnection -Profile ([pscustomobject]@{ Name = 'local' })

# Exercise the public apply path, with IPv4 and console output intercepted.
$ThemeAccent = $ThemeMuted = $ThemeText = $ThemeSuccess = $ThemeError = $ThemeWarning = 'Gray'
$ShowDeviceInfo = $true
$script:IpWrites = 0
$script:ApplyResult = ''
function Show-Header {}
function Write-Line {}
function Pause-Menu {}
function Write-Color { param($Text, $Color, [switch]$NoNewline) }
function Invoke-NetshAddress { param($IP, $Mask, $Gateway, $Operation, $Store) $script:IpWrites++ }
function Write-OperationLog {
    param($Action, $Result, $Details)
    if ($Action -eq 'ApplyProfile') { $script:ApplyResult = $Result }
}
$profile = [pscustomobject]@{
    Name = 'local'; Mode = 'Network'; VLAN = $null
    IP = '192.168.123.12'; Mask = '255.255.255.0'; Gateway = '192.168.123.1'
}
Apply-Profile -Profile $profile
Assert-True ($script:IpWrites -eq 0 -and $script:ApplyResult -eq 'Error') 'Replacement was not blocked before IPv4'
$script:Adapters = @([pscustomobject]@{ Name = $script:AdapterName; InterfaceGuid = $script:AdapterGuid })
$intel.RegistryValue = $null
$script:Properties = @($priority, $intel)
Apply-Profile -Profile $profile
Assert-True ($script:IpWrites -eq 1 -and $script:ApplyResult -eq 'Success') 'Untagged profile without PingTarget failed'
$profile.VLAN = 100
Apply-Profile -Profile $profile
Assert-True ($script:IpWrites -eq 1 -and $script:ApplyResult -eq 'Error') 'Unsupported tagged profile changed IPv4'
Write-Output 'PASS: Intel, ASIX, driver default, cache invalidation, read failure, adapter replacement, missing PingTarget.'
