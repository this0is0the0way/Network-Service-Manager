#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppName = 'BESKAR Network Manager'
$AppVersion = '2.5.4'

$ProfilesDirectory = Join-Path $PSScriptRoot 'Profiles'
$script:CurrentObjectName = $null
$script:CurrentProfilesPath = $null
$AdapterProfilesPath = Join-Path $PSScriptRoot 'AdapterProfiles.json'
$ThemePath = Join-Path $PSScriptRoot 'Theme.json'
$SnapshotPath = Join-Path $PSScriptRoot 'OriginalNetworkState.json'
$LogDirectory = Join-Path $PSScriptRoot 'Logs'
$StartupErrorLog = Join-Path $PSScriptRoot 'StartupError.log'

# ============================================================
#                 НАСТРОЙКИ ПОЛЬЗОВАТЕЛЯ
# ============================================================

# Показывать название подключаемого устройства из DeviceName.
# $false = скрыто
# $true  = показывать
$ShowDeviceInfo = $true

# Автоматически проверять PingTarget после применения профиля.
# $false = проверка отключена
# $true  = проверка включена
$EnablePing = $true

# Количество отправляемых ping-пакетов.
$PingCount = 2

# Максимальное ожидание ответа на каждый пакет, миллисекунды.
$PingTimeout = 500
$PingDelayAfterApply = 5000   # ожидание восстановления сети после применения профиля, мс
$PingRetryCount = 5            # максимальное количество попыток
$PingRetryDelay = 1000         # задержка между попытками, мс


# Максимальное ожидание команды ipconfig /renew, секунды.
$DhcpRenewTimeoutSeconds = 8

# Показывать приветственную анимацию при запуске.
# $false = отключена
# $true  = включена
$EnableStartupAnimation = $true

# Размер окна PowerShell в символах.
# Подходит для классического PowerShell / conhost.
$ConsoleWindowWidth  = 140
$ConsoleWindowHeight = 50
$ConsoleBufferHeight = 3000



# ============================================================


# ============================================================
#                 НАСТРОЙКИ ИНТЕРФЕЙСА
# ============================================================
# Допустимые цвета:
# Black, DarkBlue, DarkGreen, DarkCyan, DarkRed, DarkMagenta,
# DarkYellow, Gray, DarkGray, Blue, Green, Cyan, Red, Magenta,
# Yellow, White
#
# ВАЖНО: если фон сделать светлым, подберите контрастный $ThemeText.

$ThemeBackground = 'Black'       # Фон окна
$ThemeText       = 'White'       # Основной текст
$ThemeTitle      = 'Cyan'        # Логотип / название
$ThemeAccent     = 'Yellow'      # Заголовки действий
$ThemeSuccess    = 'Green'       # Успех / Up
$ThemeWarning    = 'DarkYellow'  # Предупреждения
$ThemeError      = 'Red'         # Ошибки / Disconnected
$ThemeMuted      = 'DarkGray'    # Второстепенный текст
$ThemeBorder     = 'DarkCyan'    # Разделительные линии
$ThemeMenuNumber = 'Cyan'        # Номера пунктов меню

# ============================================================

$script:AdapterName = $null
$script:AdapterGuid = $null
$script:VlanProperty = $null
$script:AdapterCapability = $null
$script:MenuMap = @{}

function Write-Color {
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text = '',

        [ConsoleColor]$Color = [ConsoleColor]::Gray,

        [switch]$NoNewline
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}

function Write-Line {
    Write-Color -Text ('═' * 78) -Color $ThemeBorder
}

function Pause-Menu {
    Write-Host ''
    Write-Color -Text 'Нажмите Enter, чтобы вернуться в меню...' -Color $ThemeMuted
    [void](Read-Host)
}

function Show-Header {
    Clear-Host

    Write-Color -Text @"
██████╗ ███████╗███████╗██╗  ██╗ █████╗ ██████╗
██╔══██╗██╔════╝██╔════╝██║ ██╔╝██╔══██╗██╔══██╗
██████╔╝█████╗  ███████╗█████╔╝ ███████║██████╔╝
██╔══██╗██╔══╝  ╚════██║██╔═██╗ ██╔══██║██╔══██╗
██████╔╝███████╗███████║██║  ██╗██║  ██║██║  ██║
╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
"@ -Color $ThemeTitle

    Write-Color -Text "$AppName v$AppVersion" -Color $ThemeText
    Write-Color -Text 'Industrial Automation Tools for ZiminD' -Color $ThemeMuted
    Write-Line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Restart-AsAdministrator {
    $arguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $PSCommandPath)
    )

    Start-Process `
        -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList $arguments

    exit
}

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }
}

function Write-OperationLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Result,

        [string]$Details = ''
    )

    try {
        Ensure-LogDirectory

        $logPath = Join-Path `
            $LogDirectory `
            ('BESKAR_{0:yyyy-MM}.log' -f (Get-Date))

        $line = '{0:yyyy-MM-dd HH:mm:ss} | Adapter={1} | Action={2} | Result={3} | {4}' -f `
            (Get-Date),
            $script:AdapterName,
            $Action,
            $Result,
            $Details

        Add-Content `
            -LiteralPath $logPath `
            -Value $line `
            -Encoding UTF8
    }
    catch {
        # Ошибка журнала не должна останавливать программу.
    }
}

function Ensure-ProfilesDirectory {
    if (-not (Test-Path -LiteralPath $ProfilesDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $ProfilesDirectory |
            Out-Null
    }
}

function Get-ObjectFiles {
    Ensure-ProfilesDirectory

    return @(
        Get-ChildItem `
            -LiteralPath $ProfilesDirectory `
            -Filter '*.json' `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object BaseName
    )
}

function Get-Profiles {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = $script:CurrentProfilesPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Не найден файл профилей объекта: $Path"
    }

    $raw = Get-Content `
        -LiteralPath $Path `
        -Raw `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return
    }

    try {
        $parsed = ConvertFrom-Json -InputObject $raw

        # В Windows PowerShell 5.1 верхнеуровневый JSON-массив иногда
        # приходит как один Object[] вместо отдельных объектов конвейера.
        # Явно отдаём каждый профиль отдельно, чтобы меню не склеивало
        # все Name в одну строку.
        if ($parsed -is [System.Array]) {
            foreach ($profile in $parsed) {
                Write-Output $profile
            }
        }
        else {
            Write-Output $parsed
        }
    }
    catch {
        throw "Ошибка JSON в файле '$Path': $($_.Exception.Message)"
    }
}

function Test-ValidObjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $invalid = [IO.Path]::GetInvalidFileNameChars()

    foreach ($char in $invalid) {
        if ($Name.Contains([string]$char)) {
            return $false
        }
    }

    return $true
}

function New-ObjectProfilesFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectName
    )

    Ensure-ProfilesDirectory

    if (-not (Test-ValidObjectName -Name $ObjectName)) {
        throw "Название объекта пустое или содержит недопустимые символы имени файла."
    }

    $path = Join-Path $ProfilesDirectory ($ObjectName + '.json')

    if (Test-Path -LiteralPath $path) {
        throw "Объект '$ObjectName' уже существует."
    }

    '[]' | Set-Content -LiteralPath $path -Encoding UTF8

    Write-OperationLog `
        -Action 'CreateObject' `
        -Result 'Success' `
        -Details "Object=$ObjectName"

    return $path
}

function Select-ObjectMenu {
    param(
        [switch]$AllowCreate
    )

    while ($true) {
        Show-Header
        Write-Color -Text 'Объекты' -Color $ThemeAccent
        Write-Host ''

        $objects = @(Get-ObjectFiles)

        if ($objects.Count -eq 0) {
            Write-Color `
                -Text 'Пока нет ни одного объекта.' `
                -Color $ThemeWarning
            Write-Host ''
        }
        else {
            for ($index = 0; $index -lt $objects.Count; $index++) {
                Write-Color `
                    -Text ('  {0,2}. ' -f ($index + 1)) `
                    -Color $ThemeMenuNumber `
                    -NoNewline

                Write-Color `
                    -Text $objects[$index].BaseName `
                    -Color $ThemeText
            }
        }

        Write-Host ''

        Write-Color -Text '  90. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text 'Обновить список объектов' -Color $ThemeText

        if ($AllowCreate) {
            Write-Color -Text '  91. ' -Color $ThemeMenuNumber -NoNewline
            Write-Color -Text 'Создать новый объект' -Color $ThemeText
        }

        Write-Color -Text '   0. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color `
            -Text $(if ($AllowCreate) { 'Назад без создания профиля' } else { 'Выход из программы' }) `
            -Color $ThemeText

        $selection = (Read-Host 'Выберите объект или команду').Trim()

        if ($selection -eq '0') {
            return $false
        }

        if ($selection -eq '90') {
            continue
        }

        if ($AllowCreate -and $selection -eq '91') {
            Write-Host ''
            Write-Color -Text 'Создание нового объекта' -Color $ThemeAccent
            Write-Color `
                -Text 'Название станет именем JSON-файла в папке Profiles.' `
                -Color $ThemeMuted
            Write-Color `
                -Text 'Введите exit или cancel, чтобы вернуться без создания объекта.' `
                -Color $ThemeWarning

            $name = (Read-Host 'Название объекта').Trim()

            if (Test-WizardCancelInput -Value $name) {
                return $false
            }

            try {
                $newPath = New-ObjectProfilesFile -ObjectName $name
                $script:CurrentObjectName = $name
                $script:CurrentProfilesPath = $newPath
                return $true
            }
            catch {
                Write-Color -Text $_.Exception.Message -Color $ThemeError
                Pause-Menu
                continue
            }
        }

        $number = 0

        if (
            [int]::TryParse($selection, [ref]$number) -and
            $number -ge 1 -and
            $number -le $objects.Count
        ) {
            $script:CurrentObjectName = $objects[$number - 1].BaseName
            $script:CurrentProfilesPath = $objects[$number - 1].FullName
            return $true
        }

        Write-Color -Text 'Такого объекта нет.' -Color $ThemeError
        Start-Sleep -Milliseconds 800
    }
}

function Get-ProfileMode {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if ($Profile.PSObject.Properties.Name -contains 'Mode') {
        $mode = [string]$Profile.Mode

        if (-not [string]::IsNullOrWhiteSpace($mode)) {
            return $mode
        }
    }

    $hasAddresses = $Profile.PSObject.Properties.Name -contains 'Addresses'
    $hasRoutes = $Profile.PSObject.Properties.Name -contains 'Routes'

    if ($hasAddresses -and $hasRoutes) {
        return 'Mixed'
    }

    if ($hasAddresses) {
        return 'MultiAddress'
    }

    if ($hasRoutes) {
        return 'Routes'
    }

    return 'Network'
}

function Get-ProfileVlan {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if (-not ($Profile.PSObject.Properties.Name -contains 'VLAN')) {
        return $null
    }

    if ($null -eq $Profile.VLAN) {
        return $null
    }

    $text = ([string]$Profile.VLAN).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $number = 0

    if (-not [int]::TryParse($text, [ref]$number)) {
        throw "Некорректный VLAN в профиле '$($Profile.Name)': $text"
    }

    if ($number -lt 1 -or $number -gt 4094) {
        throw "VLAN должен находиться в диапазоне 1–4094."
    }

    return $number
}


function Get-AdapterDriverMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $adapter = Get-NetAdapter -Name $Name -ErrorAction Stop

    $allProperties = @(
        Get-NetAdapterAdvancedProperty `
            -Name $Name `
            -AllProperties `
            -ErrorAction SilentlyContinue
    )

    function Get-RegistryTextValue {
        param([string]$Keyword)

        $item = $allProperties |
            Where-Object { $_.RegistryKeyword -eq $Keyword } |
            Select-Object -First 1

        if ($null -eq $item -or $null -eq $item.RegistryValue) {
            return ''
        }

        $values = @($item.RegistryValue)
        if ($values.Count -eq 0) {
            return ''
        }

        return [string]$values[0]
    }

    [pscustomobject]@{
        Name = [string]$adapter.Name
        InterfaceDescription = [string]$adapter.InterfaceDescription
        DriverVersion = Get-RegistryTextValue -Keyword 'DriverVersion'
        ProviderName = Get-RegistryTextValue -Keyword 'ProviderName'
        MatchingDeviceId = Get-RegistryTextValue -Keyword 'MatchingDeviceId'
        MacAddress = [string]$adapter.MacAddress
    }
}

function Get-AdapterProfileDatabase {
    if (-not (Test-Path -LiteralPath $AdapterProfilesPath)) {
        return @()
    }

    try {
        $raw = Get-Content `
            -LiteralPath $AdapterProfilesPath `
            -Raw `
            -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        return @(ConvertFrom-Json -InputObject $raw)
    }
    catch {
        Write-OperationLog `
            -Action 'LoadAdapterProfiles' `
            -Result 'Warning' `
            -Details $_.Exception.Message

        return @()
    }
}

function Save-AdapterProfileDatabase {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles
    )

    $Profiles |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $AdapterProfilesPath `
            -Encoding UTF8
}

function Get-AdapterProfileKey {
    param(
        [Parameter(Mandatory = $true)]
        $Metadata
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Metadata.MatchingDeviceId)) {
        return ('{0}|{1}' -f $Metadata.MatchingDeviceId, $Metadata.DriverVersion)
    }

    return ('{0}|{1}|{2}' -f `
        $Metadata.ProviderName,
        $Metadata.InterfaceDescription,
        $Metadata.DriverVersion)
}

function Find-SavedAdapterCapability {
    param(
        [Parameter(Mandatory = $true)]
        $Metadata
    )

    $key = Get-AdapterProfileKey -Metadata $Metadata
    $database = @(Get-AdapterProfileDatabase)

    return $database |
        Where-Object { [string]$_.Key -eq $key } |
        Select-Object -First 1
}

function Get-VlanCandidateProperties {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $properties = @(
        Get-NetAdapterAdvancedProperty `
            -Name $Name `
            -AllProperties `
            -ErrorAction Stop
    )

    $ranked = foreach ($property in $properties) {
        $score = 0
        $displayName = [string]$property.DisplayName
        $keyword = [string]$property.RegistryKeyword

        # Сильные известные совпадения.
        if ($keyword -match '^(VLAN_ID|RegVlanID|VlanID|VLANID|\*VlanID)$') {
            $score += 100
        }

        # Общий fallback по имени параметра.
        if ($keyword -match 'VLAN' -and $keyword -match 'ID') {
            $score += 50
        }

        # DisplayName "VLAN ID" — хороший признак.
        if ($displayName -match '^VLAN\s*ID$') {
            $score += 80
        }
        elseif ($displayName -match 'VLAN.*ID') {
            $score += 40
        }

        # Priority & VLAN — это не числовой VLAN ID.
        if (
            $displayName -match 'Priority' -or
            $keyword -match 'PriorityVLANTag'
        ) {
            continue
        }

        if ($score -gt 0) {
            [pscustomobject]@{
                Property = $property
                Score = $score
                # Совпадение только по скрытому имени (IntelANSVlanID и т.п.)
                # не доказывает возможность прямой настройки VLAN.
                CanSetVlan = ($keyword -match '^(VLAN_ID|RegVlanID|VlanID|VLANID|\*VlanID)$' -or
                    $displayName -match 'VLAN.*ID')
            }
        }
    }

    return @(
        $ranked |
            Sort-Object Score -Descending
    )
}

function Resolve-VlanDisableStrategy {
    param(
        [Parameter(Mandatory = $true)]
        $Property
    )

    # Optional=True обычно означает, что "отсутствует" корректно
    # представляется удалением драйверного свойства.
    if ($Property.PSObject.Properties.Name -contains 'Optional' -and [bool]$Property.Optional) {
        return [pscustomobject]@{
            Method = 'RemoveProperty'
            DisabledValue = $null
            Reason = 'Свойство драйвера помечено как Optional.'
        }
    }

    # Если свойство нельзя удалить, используем документированное
    # самим драйвером значение по умолчанию.
    if ($Property.PSObject.Properties.Name -contains 'DefaultRegistryValue' -and
        $null -ne $Property.DefaultRegistryValue) {
        $values = @($Property.DefaultRegistryValue)

        if ($values.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$values[0])) {
            return [pscustomobject]@{
                Method = 'SetValue'
                DisabledValue = [string]$values[0]
                Reason = 'Используется DefaultRegistryValue драйвера.'
            }
        }
    }

    return [pscustomobject]@{
        Method = 'Unknown'
        DisabledValue = $null
        Reason = 'Безопасный способ сброса автоматически не определён.'
    }
}

function Detect-AdapterCapability {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $metadata = Get-AdapterDriverMetadata -Name $Name

    # ВАЖНО:
    # Каждый раз сначала реально читаем свойства ТЕКУЩЕГО драйвера.
    # AdapterProfiles.json используется как кэш/память, но не как источник истины.
    # Это не позволяет старой ошибочной записи "SupportsVlan=false"
    # сломать адаптер после обновления драйвера или неудачного определения.
    $candidates = @(Get-VlanCandidateProperties -Name $Name)

    if ($candidates.Count -gt 0) {
        $best = $candidates[0]
        $property = $best.Property
        $strategy = Resolve-VlanDisableStrategy -Property $property

        $confidence = if ($best.Score -ge 100) {
            'High'
        }
        elseif ($best.Score -ge 70) {
            'Medium'
        }
        else {
            'Low'
        }

        # База хранит результат обнаружения, но не заменяет текущие метаданные.
        $disableMethod = [string]$strategy.Method
        $disabledValue = $strategy.DisabledValue
        $source = 'Detected'
        if (-not $best.CanSetVlan) {
            $disableMethod = 'Unknown'
            $disabledValue = $null
        }

        $capability = [pscustomobject][ordered]@{
            Key = Get-AdapterProfileKey -Metadata $metadata
            InterfaceDescription = $metadata.InterfaceDescription
            ProviderName = $metadata.ProviderName
            DriverVersion = $metadata.DriverVersion
            MatchingDeviceId = $metadata.MatchingDeviceId
            SupportsVlan = [bool]$best.CanSetVlan
            VlanKeyword = [string]$property.RegistryKeyword
            VlanDisplayName = [string]$property.DisplayName
            DisableMethod = $disableMethod
            DisabledValue = $disabledValue
            Confidence = $confidence
            LastSeen = (Get-Date).ToString('s')
            Source = $source
        }

        Save-DetectedAdapterCapability -Capability $capability
        return $capability
    }

    $capability = [pscustomobject][ordered]@{
        Key = Get-AdapterProfileKey -Metadata $metadata
        InterfaceDescription = $metadata.InterfaceDescription
        ProviderName = $metadata.ProviderName
        DriverVersion = $metadata.DriverVersion
        MatchingDeviceId = $metadata.MatchingDeviceId
        SupportsVlan = $false
        VlanKeyword = $null
        VlanDisplayName = $null
        DisableMethod = 'Unsupported'
        DisabledValue = $null
        Confidence = 'High'
        LastSeen = (Get-Date).ToString('s')
        Source = 'Detected'
    }

    Save-DetectedAdapterCapability -Capability $capability
    return $capability
}

function Save-DetectedAdapterCapability {
    param(
        [Parameter(Mandatory = $true)]
        $Capability
    )

    $database = @(Get-AdapterProfileDatabase)
    $key = [string]$Capability.Key
    $updated = @()
    $replaced = $false

    foreach ($item in $database) {
        if ([string]$item.Key -eq $key) {
            $updated += $Capability
            $replaced = $true
        }
        else {
            $updated += $item
        }
    }

    if (-not $replaced) {
        $updated += $Capability
    }

    Save-AdapterProfileDatabase -Profiles @($updated)
}

function Get-CurrentAdapterVlanProperty {
    if (
        $null -eq $script:AdapterCapability -or
        [string]::IsNullOrWhiteSpace([string]$script:AdapterCapability.VlanKeyword)
    ) {
        return $null
    }

    return Get-NetAdapterAdvancedProperty `
        -Name $script:AdapterName `
        -RegistryKeyword ([string]$script:AdapterCapability.VlanKeyword) `
        -AllProperties `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Show-AdapterCapabilitySummary {
    if ($null -eq $script:AdapterCapability) {
        return
    }

    Write-Host ''
    Write-Color -Text 'Профиль адаптера' -Color $ThemeAccent

    Write-Color -Text '  Драйвер     : ' -Color $ThemeMuted -NoNewline
    Write-Color `
        -Text ([string]$script:AdapterCapability.InterfaceDescription) `
        -Color $ThemeText

    Write-Color -Text '  VLAN        : ' -Color $ThemeMuted -NoNewline

    if ([bool]$script:AdapterCapability.SupportsVlan) {
        Write-Color `
            -Text ('поддерживается ({0})' -f $script:AdapterCapability.VlanKeyword) `
            -Color $ThemeSuccess

        Write-Color -Text '  Сброс VLAN  : ' -Color $ThemeMuted -NoNewline

        switch ([string]$script:AdapterCapability.DisableMethod) {
            'RemoveProperty' {
                Write-Color -Text 'удаление свойства → «отсутствует»' -Color $ThemeText
            }

            'SetValue' {
                Write-Color `
                    -Text ('значение {0}' -f $script:AdapterCapability.DisabledValue) `
                    -Color $ThemeText
            }

            default {
                Write-Color `
                    -Text 'не определён автоматически' `
                    -Color $ThemeWarning
            }
        }
    }
    else {
        Write-Color `
            -Text ('прямая настройка VLAN ID не подтверждена; кандидат: {0}' -f $script:AdapterCapability.VlanKeyword) `
            -Color $ThemeWarning
    }

    Write-Color -Text '  Определение  : ' -Color $ThemeMuted -NoNewline
    Write-Color `
        -Text ('{0}, confidence={1}' -f `
            $script:AdapterCapability.Source,
            $script:AdapterCapability.Confidence) `
        -Color $ThemeMuted
}


function Find-VlanProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (
        $Name -eq $script:AdapterName -and
        $null -ne $script:AdapterCapability
    ) {
        return Get-CurrentAdapterVlanProperty
    }

    $candidates = @(Get-VlanCandidateProperties -Name $Name)

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].Property
}

function Get-CurrentVlanText {
    if ($null -ne $script:AdapterCapability -and
        -not $script:AdapterCapability.SupportsVlan -and
        -not [string]::IsNullOrWhiteSpace([string]$script:AdapterCapability.VlanKeyword)) {
        return ('управление не подтверждено ({0})' -f $script:AdapterCapability.VlanKeyword)
    }
    if ($null -eq $script:VlanProperty) {
        return 'не поддерживается'
    }

    $property = Find-VlanProperty -Name $script:AdapterName

    if ($null -eq $property) {
        return 'отсутствует'
    }

    if ($null -eq $property.RegistryValue) {
        return 'отсутствует'
    }

    $values = @($property.RegistryValue)

    if ($values.Count -eq 0) {
        return 'отсутствует'
    }

    return [string]$values[0]
}

function Get-AdapterState {
    $adapter = Get-NetAdapter `
        -Name $script:AdapterName `
        -ErrorAction Stop

    $ipInterface = Get-NetIPInterface `
        -InterfaceAlias $script:AdapterName `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $addresses = @(
        Get-NetIPAddress `
            -InterfaceAlias $script:AdapterName `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object IPAddress, PrefixLength, PrefixOrigin
    )

    $defaultGateways = @(
        Get-NetRoute `
            -InterfaceAlias $script:AdapterName `
            -AddressFamily IPv4 `
            -DestinationPrefix '0.0.0.0/0' `
            -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) -and
            $_.NextHop -ne '0.0.0.0'
        } |
        Sort-Object RouteMetric |
        Select-Object -ExpandProperty NextHop -Unique
    )

    [pscustomobject]@{
        Status = [string]$adapter.Status
        LinkSpeed = [string]$adapter.LinkSpeed
        Dhcp = if ($null -ne $ipInterface) {
            [string]$ipInterface.Dhcp
        }
        else {
            'неизвестно'
        }
        Addresses = $addresses
        Gateways = $defaultGateways
        Vlan = Get-CurrentVlanText
    }
}

function Save-OriginalState {
    if (Test-Path -LiteralPath $SnapshotPath) {
        return
    }

    try {
        $state = Get-AdapterState

        $dnsServers = @(
            (
                Get-DnsClientServerAddress `
                    -InterfaceAlias $script:AdapterName `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue
            ).ServerAddresses
        )

        $snapshot = [ordered]@{
            AdapterName = $script:AdapterName
            VlanKeyword = if ($null -ne $script:VlanProperty) {
                [string]$script:VlanProperty.RegistryKeyword
            }
            else {
                $null
            }
            VlanValue = if (
                $null -ne $script:VlanProperty -and
                $null -ne $script:VlanProperty.RegistryValue
            ) {
                @($script:VlanProperty.RegistryValue)
            }
            else {
                $null
            }
            Dhcp = $state.Dhcp
            Addresses = @($state.Addresses)
            DnsServers = $dnsServers
            SavedAt = (Get-Date).ToString('s')
        }

        $snapshot |
            ConvertTo-Json -Depth 8 |
            Set-Content `
                -LiteralPath $SnapshotPath `
                -Encoding UTF8
    }
    catch {
        Write-OperationLog `
            -Action 'SaveOriginalState' `
            -Result 'Warning' `
            -Details $_.Exception.Message
    }
}

function Update-SelectedAdapterCapability {
    # Повторный поиск перед отображением меню и перед каждой сетевой операцией.
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
    $current = @($adapters | Where-Object { $_.Name -eq $script:AdapterName })
    if ($current.Count -ne 1 -or
        [string]$current[0].InterfaceGuid -ne [string]$script:AdapterGuid) {
        $script:AdapterCapability = $null
        $script:VlanProperty = $null
        throw 'Выбранный адаптер отключён, переименован или заменён. Выберите адаптер заново командой adapter.'
    }

    Initialize-SelectedAdapterCapability
}

function Initialize-SelectedAdapterCapability {
    # После подключения кабеля или USB-адаптера драйвер иногда кратковременно
    # не отдаёт расширенные свойства. Повторяем только чтение, не отключая адаптер.
    $lastError = $null

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $script:AdapterCapability = $null
            $script:VlanProperty = $null
            $script:AdapterCapability = Detect-AdapterCapability -Name $script:AdapterName
            $script:VlanProperty = Get-CurrentAdapterVlanProperty
            return
        }
        catch {
            $lastError = $_
            $script:AdapterCapability = $null
            $script:VlanProperty = $null

            if ($attempt -lt 4) {
                Write-OperationLog `
                    -Action 'AdapterInitialization' `
                    -Result 'Retry' `
                    -Details ("Attempt={0}; {1}" -f $attempt, $_.Exception.Message)
                Start-Sleep -Milliseconds 1500
            }
        }
    }

    throw ("Не удалось инициализировать адаптер «{0}» после 4 попыток. {1}" -f `
        $script:AdapterName, $lastError.Exception.Message)
}

function Select-NetworkAdapter {
    while ($true) {
        Show-Header
        Write-Color -Text 'Выбор сетевого адаптера' -Color $ThemeAccent
        Write-Host ''

        $adapters = @(
            Get-NetAdapter `
                -Physical `
                -ErrorAction Stop |
            Sort-Object Name
        )

        if ($adapters.Count -eq 0) {
            Write-Color `
                -Text 'Физические сетевые адаптеры не найдены.' `
                -Color $ThemeError
            Pause-Menu
            exit 1
        }

        for ($index = 0; $index -lt $adapters.Count; $index++) {
            $adapter = $adapters[$index]
            $candidates = @()
            try {
                $candidates = @(Get-VlanCandidateProperties -Name $adapter.Name | Where-Object { $_.CanSetVlan })
            }
            catch {
                Write-Color -Text ('Не удалось прочитать свойства {0}: {1}' -f $adapter.Name, $_.Exception.Message) -Color $ThemeWarning
            }

            Write-Color `
                -Text ('  {0,2}. ' -f ($index + 1)) `
                -Color $ThemeMenuNumber `
                -NoNewline

            Write-Color `
                -Text ([string]$adapter.Name) `
                -Color $ThemeText `
                -NoNewline

            Write-Color `
                -Text ('  [{0}]' -f $adapter.Status) `
                -Color $ThemeMuted `
                -NoNewline

            if ($candidates.Count -gt 0) {
                Write-Color `
                    -Text ('  VLAN: найден кандидат {0}' -f `
                        $candidates[0].Property.RegistryKeyword) `
                    -Color $ThemeSuccess
            }
            else {
                Write-Color `
                    -Text '  VLAN ID не найден; профили без VLAN доступны' `
                    -Color $ThemeWarning
            }

            Write-Color `
                -Text ('      {0}' -f $adapter.InterfaceDescription) `
                -Color $ThemeMuted
        }

        Write-Host ''
        Write-Color -Text '  90. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text 'Обновить список и состояние адаптеров' -Color $ThemeText

        Write-Color -Text '   0. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text 'Выход из программы' -Color $ThemeText

        $selection = (Read-Host 'Введите номер адаптера или команду').Trim()

        if ($selection -eq '0') {
            exit
        }

        if ($selection -eq '90') {
            continue
        }

        $number = 0

        if (
            [int]::TryParse($selection, [ref]$number) -and
            $number -ge 1 -and
            $number -le $adapters.Count
        ) {
            $script:AdapterName = [string]$adapters[$number - 1].Name
            $script:AdapterGuid = [string]$adapters[$number - 1].InterfaceGuid

            Show-Header
            Write-Color -Text 'Анализ сетевого адаптера (чтение текущего драйвера)...' -Color $ThemeAccent
            Write-Host ''
            Write-Color -Text ('  {0}' -f $script:AdapterName) -Color $ThemeText
            Write-Color `
                -Text ('  {0}' -f $adapters[$number - 1].InterfaceDescription) `
                -Color $ThemeMuted
            Write-Host ''

            try {
                Initialize-SelectedAdapterCapability

                Show-AdapterCapabilitySummary
                Write-Host ''
                Write-Color -Text 'Адаптер готов.' -Color $ThemeSuccess
                Start-Sleep -Milliseconds 900
            }
            catch {
                $script:AdapterCapability = $null
                $script:VlanProperty = $null

                Write-Color `
                    -Text 'Не удалось полностью проанализировать VLAN-возможности.' `
                    -Color $ThemeWarning
                Write-Color -Text $_.Exception.Message -Color $ThemeWarning
                Write-Color `
                    -Text 'Выберите адаптер заново или обновите список командой 90.' `
                    -Color $ThemeMuted
                Pause-Menu
                continue
            }

            Save-OriginalState
            return
        }

        Write-Color -Text 'Неверный номер адаптера.' -Color $ThemeError
        Start-Sleep -Seconds 1
    }
}

function Show-CurrentState {
    try {
        $state = Get-AdapterState

        Write-Color -Text 'Текущее состояние' -Color $ThemeAccent
        Write-Host ''

        Write-Color -Text '  Адаптер : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $script:AdapterName -Color $ThemeText

        Write-Color -Text '  Статус  : ' -Color $ThemeMuted -NoNewline

        $statusColor = switch ($state.Status) {
            'Up'           { [ConsoleColor]$ThemeSuccess }
            'Disconnected' { [ConsoleColor]$ThemeError }
            'Disabled'     { [ConsoleColor]$ThemeError }
            default        { [ConsoleColor]$ThemeWarning }
        }

        Write-Color -Text $state.Status -Color $statusColor

        Write-Color -Text '  VLAN    : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $state.Vlan -Color $ThemeText

        Write-Color -Text '  IPv4    : ' -Color $ThemeMuted -NoNewline

        if ($state.Addresses.Count -eq 0) {
            Write-Color -Text 'не назначен' -Color $ThemeText
        }
        else {
            $addressText = (
                $state.Addresses |
                ForEach-Object {
                    '{0}/{1}' -f $_.IPAddress, $_.PrefixLength
                }
            ) -join ', '

            Write-Color -Text $addressText -Color $ThemeText
        }

        Write-Color -Text '  DHCP    : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $state.Dhcp -Color $ThemeText

        Write-Color -Text '  Шлюз    : ' -Color $ThemeMuted -NoNewline

        if ($state.Gateways.Count -eq 0) {
            Write-Color -Text 'не задан' -Color $ThemeText
        }
        else {
            Write-Color -Text ($state.Gateways -join ', ') -Color $ThemeText
        }

        Write-Color -Text '  Скорость: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $state.LinkSpeed -Color $ThemeText

        if ($null -ne $script:AdapterCapability) {
            Write-Color -Text '  VLAN drv: ' -Color $ThemeMuted -NoNewline

            if ([bool]$script:AdapterCapability.SupportsVlan) {
                Write-Color `
                    -Text ([string]$script:AdapterCapability.VlanKeyword) `
                    -Color $ThemeText
            }
            else {
                Write-Color -Text ('не подтверждён ({0})' -f $script:AdapterCapability.VlanKeyword) -Color $ThemeWarning
            }
        }

        Write-Line
    }
    catch {
        Write-Color `
            -Text "Не удалось прочитать состояние: $($_.Exception.Message)" `
            -Color $ThemeError
        Write-Line
    }
}

function Remove-CurrentVlan {
    # Сначала берём актуальное свойство из capability.
    $property = Get-CurrentAdapterVlanProperty

    # Если capability оказался устаревшим/ошибочным — читаем драйвер напрямую.
    if ($null -eq $property) {
        $directCandidates = @(Get-VlanCandidateProperties -Name $script:AdapterName)

        if ($directCandidates.Count -gt 0) {
            $property = $directCandidates[0].Property
            $script:AdapterCapability = Detect-AdapterCapability -Name $script:AdapterName
            $script:VlanProperty = $property
        }
    }

    if ($null -eq $property) {
        return
    }

    # Уже отсутствующее значение не требует записи или удаления свойства.
    $currentValues = @($property.RegistryValue)
    if ($null -eq $property.RegistryValue -or $currentValues.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$currentValues[0])) {
        return
    }

    $method = 'Unknown'
    $disabledValue = $null

    if (
        $null -ne $script:AdapterCapability -and
        [string]$script:AdapterCapability.VlanKeyword -eq [string]$property.RegistryKeyword
    ) {
        $method = [string]$script:AdapterCapability.DisableMethod
        $disabledValue = $script:AdapterCapability.DisabledValue
    }
    else {
        $strategy = Resolve-VlanDisableStrategy -Property $property
        $method = [string]$strategy.Method
        $disabledValue = $strategy.DisabledValue
    }

    switch ($method) {
        'RemoveProperty' {
            if (
                $null -ne $property.RegistryValue -and
                @($property.RegistryValue).Count -gt 0
            ) {
                Remove-NetAdapterAdvancedProperty `
                    -Name $script:AdapterName `
                    -RegistryKeyword ([string]$property.RegistryKeyword) `
                    -NoRestart `
                    -Confirm:$false `
                    -ErrorAction Stop
            }
        }

        'SetValue' {
            Set-NetAdapterAdvancedProperty `
                -Name $script:AdapterName `
                -RegistryKeyword ([string]$property.RegistryKeyword) `
                -RegistryValue ([string]$disabledValue) `
                -NoRestart `
                -ErrorAction Stop
        }

        'Unknown' {
            throw @"
Для адаптера '$script:AdapterName' найден параметр '$($property.RegistryKeyword)' со значением '$($currentValues[0])',
но способ его отключения не подтверждён текущим драйвером.
Сброс остановлен. Packet Priority & VLAN не является полем номера VLAN.
"@
        }
    }
}


function Get-CurrentVlanRawValue {
    $property = Get-CurrentAdapterVlanProperty
    if ($null -eq $property -or $null -eq $property.RegistryValue) { return $null }

    $values = @($property.RegistryValue)
    if ($values.Count -eq 0) { return $null }

    $text = ([string]$values[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Test-VlanIsDisabled {
    $directCandidates = @(Get-VlanCandidateProperties -Name $script:AdapterName)

    if ($directCandidates.Count -eq 0) { return $true }

    $property = $directCandidates[0].Property
    if ($null -eq $property.RegistryValue) { return $true }

    $values = @($property.RegistryValue)
    if ($values.Count -eq 0) { return $true }

    $current = ([string]$values[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($current)) { return $true }

    if (
        $null -ne $script:AdapterCapability -and
        [string]$script:AdapterCapability.DisableMethod -eq 'SetValue' -and
        $current -eq [string]$script:AdapterCapability.DisabledValue
    ) { return $true }

    return $false
}

function Disable-VlanAndVerify {
    $before = Get-CurrentVlanRawValue
    Remove-CurrentVlan
    Start-Sleep -Milliseconds 500

    try {
        $script:AdapterCapability = Detect-AdapterCapability -Name $script:AdapterName
        $script:VlanProperty = Get-CurrentAdapterVlanProperty
    }
    catch {
        # Финальная проверка ниже читает драйвер напрямую.
    }

    if (-not (Test-VlanIsDisabled)) {
        $after = Get-CurrentVlanRawValue
        throw @"
Не удалось снять VLAN с адаптера '$script:AdapterName'.
До сброса: $before
После сброса: $after

IP-настройки профиля не применены.
"@
    }

    Write-OperationLog -Action 'DisableVLAN' -Result 'Success' -Details "Before=$before"
}

function Set-RequestedVlan {
    param(
        $Value
    )

    if ($null -eq $Value) {
        Disable-VlanAndVerify
        return
    }

    # Capability обновляется перед операцией; слабый кандидат не повышается
    # до поддерживаемого параметра повторным поиском по одному имени.
    $keyword = $null

    if (
        $null -ne $script:AdapterCapability -and
        [bool]$script:AdapterCapability.SupportsVlan -and
        -not [string]::IsNullOrWhiteSpace([string]$script:AdapterCapability.VlanKeyword)
    ) {
        $keyword = [string]$script:AdapterCapability.VlanKeyword
    }

    if ([string]::IsNullOrWhiteSpace($keyword)) {
        throw "Драйвер адаптера '$script:AdapterName' не предоставляет подтверждённый параметр для прямой настройки VLAN ID. Packet Priority & VLAN управляет обработкой тегов, а скрытый IntelANSVlanID сам по себе не подтверждает поддержку. IPv4 профиля не изменён."
    }

    Set-NetAdapterAdvancedProperty `
        -Name $script:AdapterName `
        -RegistryKeyword $keyword `
        -RegistryValue ([string]$Value) `
        -ErrorAction Stop
}

function Invoke-NetshAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string]$Mask,

        [string]$Gateway = '',

        [ValidateSet('set', 'add')]
        [string]$Operation = 'set',

        [ValidateSet('active', 'persistent')]
        [string]$Store = 'persistent'
    )

    $arguments = @(
        'interface'
        'ipv4'
        $Operation
        'address'
        "name=$script:AdapterName"
        "address=$IP"
        "mask=$Mask"
    )

    if ($Operation -eq 'set') {
        $arguments += 'source=static'

        if ([string]::IsNullOrWhiteSpace($Gateway)) {
            $arguments += 'gateway=none'
        }
        else {
            $arguments += "gateway=$Gateway"
        }
    }

    $arguments += "store=$Store"

    & netsh.exe @arguments | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "netsh завершился с кодом $LASTEXITCODE при назначении адреса $IP."
    }
}

function Add-ProfileRoute {
    param(
        [Parameter(Mandatory = $true)]
        $Route,

        [bool]$Persistent = $false
    )

    $arguments = @(
        'add'
        [string]$Route.Destination
        'mask'
        [string]$Route.Mask
        [string]$Route.Gateway
    )

    if ($Persistent) {
        $arguments = @('-p') + $arguments
    }

    & route.exe @arguments | Out-Null

    if ($LASTEXITCODE -ne 0) {
        & route.exe `
            delete `
            ([string]$Route.Destination) `
            mask `
            ([string]$Route.Mask) `
            ([string]$Route.Gateway) |
            Out-Null

        & route.exe @arguments | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Не удалось добавить маршрут $($Route.Destination)."
        }
    }
}



function Apply-NetworkProfile {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    $vlan = Get-ProfileVlan -Profile $Profile

    Write-Color -Text '► Настройка VLAN...' -Color $ThemeAccent -NoNewline
    Set-RequestedVlan -Value $vlan
    Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

    Start-Sleep -Seconds 2

    if (-not ($Profile.PSObject.Properties.Name -contains 'IP')) {
        throw "В профиле '$($Profile.Name)' отсутствует поле IP."
    }

    if (-not ($Profile.PSObject.Properties.Name -contains 'Mask')) {
        throw "В профиле '$($Profile.Name)' отсутствует поле Mask."
    }

    $gateway = ''

    if ($Profile.PSObject.Properties.Name -contains 'Gateway') {
        $gateway = [string]$Profile.Gateway
    }

    Write-Color -Text '► Настройка IPv4...' -Color $ThemeAccent -NoNewline

    Invoke-NetshAddress `
        -IP ([string]$Profile.IP) `
        -Mask ([string]$Profile.Mask) `
        -Gateway $gateway `
        -Operation set `
        -Store persistent


    Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess
}

function Apply-MultiAddressProfile {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    $vlan = Get-ProfileVlan -Profile $Profile

    Write-Color -Text '► Настройка VLAN...' -Color $ThemeAccent -NoNewline
    Set-RequestedVlan -Value $vlan
    Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

    Start-Sleep -Seconds 2

    $addresses = @($Profile.Addresses)

    if ($addresses.Count -eq 0) {
        throw "В профиле '$($Profile.Name)' массив Addresses пуст."
    }

    Write-Color `
        -Text ('► Назначение адресов: {0}...' -f $addresses.Count) `
        -Color $ThemeAccent `
        -NoNewline

    Invoke-NetshAddress `
        -IP ([string]$addresses[0].IP) `
        -Mask ([string]$addresses[0].Mask) `
        -Gateway '' `
        -Operation set `
        -Store active

    for ($index = 1; $index -lt $addresses.Count; $index++) {
        Invoke-NetshAddress `
            -IP ([string]$addresses[$index].IP) `
            -Mask ([string]$addresses[$index].Mask) `
            -Operation add `
            -Store active
    }


    Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess
}

function Apply-RoutesProfile {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    $routes = @($Profile.Routes)

    if ($routes.Count -eq 0) {
        throw "В профиле '$($Profile.Name)' массив Routes пуст."
    }

    $persistent = $false

    if ($Profile.PSObject.Properties.Name -contains 'Persistent') {
        $persistent = [bool]$Profile.Persistent
    }

    Write-Color `
        -Text ('► Добавление маршрутов: {0}...' -f $routes.Count) `
        -Color $ThemeAccent `
        -NoNewline

    foreach ($route in $routes) {
        Add-ProfileRoute `
            -Route $route `
            -Persistent $persistent
    }

    Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess
}

function Test-ProfileConnection {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if (-not $EnablePing) {
        return
    }

    if (
        -not ($Profile.PSObject.Properties.Name -contains 'PingTarget') -or
        $null -eq $Profile.PingTarget -or
        [string]::IsNullOrWhiteSpace([string]$Profile.PingTarget)
    ) {
        return
    }

    Write-Host ''
    Write-Color -Text 'Проверка PingTarget' -Color $ThemeAccent

    Write-Color -Text '  Адрес: ' -Color $ThemeMuted -NoNewline
    Write-Color -Text ([string]$Profile.PingTarget) -Color $ThemeText

    if ($PingDelayAfterApply -gt 0) {
        Write-Color -Text '  Ожидание восстановления сети...' -Color $ThemeMuted
        Start-Sleep -Milliseconds $PingDelayAfterApply
    }

    for ($attempt = 1; $attempt -le $PingRetryCount; $attempt++) {

        Write-Color `
            -Text ("  Попытка {0}/{1}" -f $attempt, $PingRetryCount) `
            -Color $ThemeMuted

        # Используем стандартный ping.exe вместо Test-Connection:
        # Windows PowerShell 5.1 не во всех системах поддерживает
        # параметр -TimeoutSeconds.
        & ping.exe `
            -n $PingCount `
            -w $PingTimeout `
            ([string]$Profile.PingTarget) | Out-Host

        $pingExitCode = $LASTEXITCODE

        if ($pingExitCode -eq 0) {
            Write-Color -Text '  Ответ получен.' -Color $ThemeSuccess

            Write-OperationLog `
                -Action 'PingTarget' `
                -Result 'Success' `
                -Details "Target=$($Profile.PingTarget);Attempt=$attempt"

            return $true
        }

        if ($attempt -lt $PingRetryCount) {
            Start-Sleep -Milliseconds $PingRetryDelay
        }
    }

    Write-Color -Text '  Устройство не отвечает.' -Color $ThemeWarning

    Write-OperationLog `
        -Action 'PingTarget' `
        -Result 'NoReply' `
        -Details "Target=$($Profile.PingTarget)"

    return $false
}

function Apply-Profile {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    Show-Header

    $mode = Get-ProfileMode -Profile $Profile

    Write-Color -Text 'Применение сетевого профиля' -Color $ThemeAccent
    Write-Host ''

    Write-Color -Text '  Профиль : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text ([string]$Profile.Name) -Color $ThemeText

    Write-Color -Text '  Режим   : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $mode -Color $ThemeText

    if (
        $ShowDeviceInfo -and
        $Profile.PSObject.Properties.Name -contains 'DeviceName' -and
        -not [string]::IsNullOrWhiteSpace([string]$Profile.DeviceName)
    ) {
        Write-Color -Text '  Устройство: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text ([string]$Profile.DeviceName) -Color $ThemeWarning
    }

    Write-Line

    try {
        Update-SelectedAdapterCapability
        switch ($mode.ToLowerInvariant()) {
            'network' {
                Apply-NetworkProfile -Profile $Profile
            }

            'multiaddress' {
                Apply-MultiAddressProfile -Profile $Profile
            }

            'routes' {
                Apply-RoutesProfile -Profile $Profile
            }

            'mixed' {
                Apply-MultiAddressProfile -Profile $Profile
                Apply-RoutesProfile -Profile $Profile
            }

            default {
                throw "Неизвестный Mode '$mode' в профиле '$($Profile.Name)'."
            }
        }

        Test-ProfileConnection -Profile $Profile

        Write-Line
        Write-Color -Text 'Профиль успешно применён.' -Color $ThemeSuccess

        Write-OperationLog `
            -Action 'ApplyProfile' `
            -Result 'Success' `
            -Details "Profile=$($Profile.Name); Mode=$mode"
    }
    catch {
        Write-Line
        Write-Color -Text 'Ошибка применения профиля.' -Color $ThemeError
        Write-Color -Text $_.Exception.Message -Color $ThemeError

        Write-OperationLog `
            -Action 'ApplyProfile' `
            -Result 'Error' `
            -Details "Profile=$($Profile.Name); $($_.Exception.Message)"
    }

    Pause-Menu
}

function Remove-StaticIPv4 {
    Get-NetRoute `
        -InterfaceAlias $script:AdapterName `
        -AddressFamily IPv4 `
        -DestinationPrefix '0.0.0.0/0' `
        -ErrorAction SilentlyContinue |
        Remove-NetRoute `
            -Confirm:$false `
            -ErrorAction SilentlyContinue

    Get-NetIPAddress `
        -InterfaceAlias $script:AdapterName `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PrefixOrigin -ne 'WellKnown'
        } |
        Remove-NetIPAddress `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
}

function Start-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -PassThru `
        -WindowStyle Hidden

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
        }
        catch {
        }

        return $false
    }

    return $true
}

function Restore-Dhcp {
    Show-Header
    Write-Color -Text 'Возврат VLAN «отсутствует» и DHCP' -Color $ThemeAccent
    Write-Host ''

    try {
        Update-SelectedAdapterCapability
        Write-Color -Text '► Удаление VLAN ID...' -Color $ThemeAccent -NoNewline
        Disable-VlanAndVerify
        Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

        Write-Color `
            -Text '► Удаление статических IPv4-параметров...' `
            -Color $ThemeAccent `
            -NoNewline

        Remove-StaticIPv4
        Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

        Write-Color -Text '► Включение DHCP и DNS...' -Color $ThemeAccent -NoNewline

        Set-NetIPInterface `
            -InterfaceAlias $script:AdapterName `
            -AddressFamily IPv4 `
            -Dhcp Enabled `
            -ErrorAction Stop

        Set-DnsClientServerAddress `
            -InterfaceAlias $script:AdapterName `
            -ResetServerAddresses `
            -ErrorAction Stop

        Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

        Write-Color -Text '► Перезапуск адаптера...' -Color $ThemeAccent -NoNewline

        Restart-NetAdapter `
            -Name $script:AdapterName `
            -Confirm:$false `
            -ErrorAction Stop

        Start-Sleep -Seconds 4
        Write-Color -Text '  ГОТОВО' -Color $ThemeSuccess

        Write-Color `
            -Text ('► Запрос DHCP, не более {0} с...' -f $DhcpRenewTimeoutSeconds) `
            -Color $ThemeAccent `
            -NoNewline

        $completed = Start-ProcessWithTimeout `
            -FilePath 'ipconfig.exe' `
            -ArgumentList @('/renew', $script:AdapterName) `
            -TimeoutSeconds $DhcpRenewTimeoutSeconds

        if ($completed) {
            Write-Color -Text '  ЗАВЕРШЕНО' -Color $ThemeSuccess
        }
        else {
            Write-Color -Text '  ВРЕМЯ ОЖИДАНИЯ ИСТЕКЛО' -Color $ThemeWarning
        }

        Write-Line
        Write-Color `
            -Text 'Режим DHCP включён. Получение адреса может продолжаться в фоне.' `
            -Color $ThemeSuccess

        Write-OperationLog `
            -Action 'RestoreDHCP' `
            -Result 'Success'
    }
    catch {
        Write-Line
        Write-Color -Text 'Ошибка восстановления DHCP.' -Color $ThemeError
        Write-Color -Text $_.Exception.Message -Color $ThemeError

        Write-OperationLog `
            -Action 'RestoreDHCP' `
            -Result 'Error' `
            -Details $_.Exception.Message
    }

    Pause-Menu
}

function Convert-PrefixToMask {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )

    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    $octets = @()

    for ($index = 0; $index -lt 4; $index++) {
        $octets += [Convert]::ToInt32(
            $bits.Substring($index * 8, 8),
            2
        )
    }

    return ($octets -join '.')
}

function Restore-OriginalState {
    Show-Header
    Write-Color -Text 'Восстановление исходного состояния' -Color $ThemeAccent
    Write-Host ''

    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        Write-Color -Text 'Снимок исходных настроек не найден.' -Color $ThemeError
        Pause-Menu
        return
    }

    try {
        Update-SelectedAdapterCapability
        $snapshot = Get-Content `
            -LiteralPath $SnapshotPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json

        if ([string]$snapshot.AdapterName -ne $script:AdapterName) {
            throw "Снимок относится к адаптеру '$($snapshot.AdapterName)'."
        }

        Remove-CurrentVlan
        Remove-StaticIPv4

        if (
            $null -ne $snapshot.VlanKeyword -and
            $null -ne $snapshot.VlanValue
        ) {
            $vlanValues = @($snapshot.VlanValue)

            if ($vlanValues.Count -gt 0) {
                Set-NetAdapterAdvancedProperty `
                    -Name $script:AdapterName `
                    -RegistryKeyword ([string]$snapshot.VlanKeyword) `
                    -RegistryValue ([string]$vlanValues[0]) `
                    -NoRestart `
                    -ErrorAction Stop
            }
        }

        if ([string]$snapshot.Dhcp -eq 'Enabled') {
            Set-NetIPInterface `
                -InterfaceAlias $script:AdapterName `
                -AddressFamily IPv4 `
                -Dhcp Enabled `
                -ErrorAction Stop
        }
        else {
            $addresses = @($snapshot.Addresses)

            if ($addresses.Count -gt 0) {
                Invoke-NetshAddress `
                    -IP ([string]$addresses[0].IPAddress) `
                    -Mask (Convert-PrefixToMask -PrefixLength ([int]$addresses[0].PrefixLength)) `
                    -Gateway '' `
                    -Operation set `
                    -Store persistent

                for ($index = 1; $index -lt $addresses.Count; $index++) {
                    Invoke-NetshAddress `
                        -IP ([string]$addresses[$index].IPAddress) `
                        -Mask (Convert-PrefixToMask -PrefixLength ([int]$addresses[$index].PrefixLength)) `
                        -Operation add `
                        -Store persistent
                }
            }
        }

        $dnsServers = @($snapshot.DnsServers)

        if ($dnsServers.Count -gt 0) {
            Set-DnsClientServerAddress `
                -InterfaceAlias $script:AdapterName `
                -ServerAddresses $dnsServers `
                -ErrorAction Stop
        }
        else {
            Set-DnsClientServerAddress `
                -InterfaceAlias $script:AdapterName `
                -ResetServerAddresses `
                -ErrorAction Stop
        }

        Restart-NetAdapter `
            -Name $script:AdapterName `
            -Confirm:$false `
            -ErrorAction Stop

        Start-Sleep -Seconds 4

        Write-Line
        Write-Color -Text 'Исходное состояние восстановлено.' -Color $ThemeSuccess

        Write-OperationLog `
            -Action 'RestoreOriginalState' `
            -Result 'Success'
    }
    catch {
        Write-Line
        Write-Color `
            -Text 'Не удалось полностью восстановить исходное состояние.' `
            -Color $ThemeError
        Write-Color -Text $_.Exception.Message -Color $ThemeError

        Write-OperationLog `
            -Action 'RestoreOriginalState' `
            -Result 'Error' `
            -Details $_.Exception.Message
    }

    Pause-Menu
}

function Get-ProfileSummary {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    $mode = Get-ProfileMode -Profile $Profile
    $vlan = Get-ProfileVlan -Profile $Profile
    $vlanText = if ($null -eq $vlan) {
        'без VLAN'
    }
    else {
        "VLAN $vlan"
    }

    switch ($mode.ToLowerInvariant()) {
        'network' {
            $ip = if ($Profile.PSObject.Properties.Name -contains 'IP') {
                [string]$Profile.IP
            }
            else {
                'IP не задан'
            }

            return ('[{0}; {1}]' -f $vlanText, $ip)
        }

        'multiaddress' {
            $addressCount = @($Profile.Addresses).Count
            return ('[{0}; {1} IP]' -f $vlanText, $addressCount)
        }

        'routes' {
            $routeCount = @($Profile.Routes).Count
            return ('[Маршруты: {0}]' -f $routeCount)
        }

        'mixed' {
            $addressCount = @($Profile.Addresses).Count
            $routeCount = @($Profile.Routes).Count
            return ('[{0}; {1} IP; {2} маршрута(ов)]' -f `
                $vlanText,
                $addressCount,
                $routeCount)
        }

        default {
            return ('[{0}]' -f $mode)
        }
    }
}

function Show-MainMenu {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles
    )

    Show-Header
    Show-CurrentState

    Write-Color -Text 'Текущий объект: ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $script:CurrentObjectName -Color $ThemeSuccess
    Write-Host ''

    if ($Profiles.Count -eq 0) {
        Write-Color -Text 'В этом объекте пока нет сетевых профилей.' -Color $ThemeWarning
        Write-Color -Text 'Введите add ip, чтобы создать первый профиль.' -Color $ThemeMuted
        Write-Host ''
    }

    $script:MenuMap = @{}
    $number = 1

    # Выравниваем названия профилей по самому длинному имени.
    $maxNameLength = 0

    if ($Profiles.Count -gt 0) {
        $maxNameLength = (
            $Profiles |
            ForEach-Object {
                if ($null -eq $_.Name) {
                    0
                }
                else {
                    ([string]$_.Name).Length
                }
            } |
            Measure-Object -Maximum
        ).Maximum
    }

    # Минимальная ширина поля имени профиля.
    if ($maxNameLength -lt 12) {
        $maxNameLength = 12
    }

    $groups = $Profiles |
        Group-Object {
            if (
                $_.PSObject.Properties.Name -contains 'Category' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.Category)
            ) {
                [string]$_.Category
            }
            else {
                'Сетевые профили'
            }
        }

    foreach ($group in $groups) {
        Write-Color -Text $group.Name -Color $ThemeAccent
        Write-Host ''

        foreach ($profile in $group.Group) {
            $profileName = [string]$profile.Name
            $alignedName = $profileName.PadRight($maxNameLength)
            $summary = Get-ProfileSummary -Profile $profile

            Write-Color `
                -Text ('  {0,2}. ' -f $number) `
                -Color $ThemeMenuNumber `
                -NoNewline

            Write-Color `
                -Text $alignedName `
                -Color $ThemeText `
                -NoNewline

            Write-Color `
                -Text ('  {0}' -f $summary) `
                -Color $ThemeMuted

            $script:MenuMap[$number] = $profile
            $number++
        }

        Write-Host ''
    }

    Write-Line
    Write-Color -Text 'Команды: ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'ping' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'edit' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'add ip' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'theme' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'objects' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'adapter' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'dhcp' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'state' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'reboot' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'help' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text ' | ' -Color $ThemeMuted -NoNewline
    Write-Color -Text 'exit' -Color $ThemeMenuNumber
    Write-Host ''
    Write-Color -Text 'Служебные номера:' -Color $ThemeAccent
    Write-Color -Text '  90  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Обновить состояние адаптера' -Color $ThemeText
    Write-Color -Text '  91  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Выбрать другой адаптер' -Color $ThemeText
    Write-Color -Text '  97  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Восстановить исходное состояние' -Color $ThemeText
    Write-Color -Text '  99  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Вернуть VLAN «отсутствует» и DHCP' -Color $ThemeText
    Write-Color -Text '   0  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Назад к выбору объектов' -Color $ThemeText
    Write-Line
}



function Get-AvailableThemeColors {
    return @(
        'Black',
        'DarkBlue',
        'DarkGreen',
        'DarkCyan',
        'DarkRed',
        'DarkMagenta',
        'DarkYellow',
        'Gray',
        'DarkGray',
        'Blue',
        'Green',
        'Cyan',
        'Red',
        'Magenta',
        'Yellow',
        'White'
    )
}

function Get-CurrentThemeObject {
    return [ordered]@{
        Background = $ThemeBackground
        Text = $ThemeText
        Title = $ThemeTitle
        Accent = $ThemeAccent
        Success = $ThemeSuccess
        Warning = $ThemeWarning
        Error = $ThemeError
        Muted = $ThemeMuted
        Border = $ThemeBorder
        MenuNumber = $ThemeMenuNumber
    }
}

function Set-ThemeVariables {
    param(
        [Parameter(Mandatory = $true)]
        $Theme
    )

    $validColors = @(Get-AvailableThemeColors)

    $map = [ordered]@{
        Background = 'ThemeBackground'
        Text = 'ThemeText'
        Title = 'ThemeTitle'
        Accent = 'ThemeAccent'
        Success = 'ThemeSuccess'
        Warning = 'ThemeWarning'
        Error = 'ThemeError'
        Muted = 'ThemeMuted'
        Border = 'ThemeBorder'
        MenuNumber = 'ThemeMenuNumber'
    }

    foreach ($entry in $map.GetEnumerator()) {
        if ($Theme.PSObject.Properties.Name -contains $entry.Key) {
            $value = [string]$Theme.($entry.Key)

            if ($validColors -contains $value) {
                Set-Variable `
                    -Name $entry.Value `
                    -Value $value `
                    -Scope Script
            }
        }
    }
}

function Apply-ConsoleTheme {
    try {
        $Host.UI.RawUI.BackgroundColor = [ConsoleColor]$ThemeBackground
        $Host.UI.RawUI.ForegroundColor = [ConsoleColor]$ThemeText
        Clear-Host
    }
    catch {
        # Некоторые терминалы могут частично игнорировать фон.
    }
}

function Load-SavedTheme {
    if (-not (Test-Path -LiteralPath $ThemePath)) {
        return
    }

    try {
        $theme = Get-Content `
            -LiteralPath $ThemePath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json

        Set-ThemeVariables -Theme $theme
    }
    catch {
        Write-OperationLog `
            -Action 'LoadTheme' `
            -Result 'Warning' `
            -Details $_.Exception.Message
    }
}

function Save-CurrentTheme {
    Get-CurrentThemeObject |
        ConvertTo-Json -Depth 4 |
        Set-Content `
            -LiteralPath $ThemePath `
            -Encoding UTF8
}

function Set-BuiltInTheme {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    switch ($Name) {
        'Classic' {
            $theme = [pscustomobject]@{
                Background = 'Black'
                Text = 'White'
                Title = 'Cyan'
                Accent = 'Yellow'
                Success = 'Green'
                Warning = 'DarkYellow'
                Error = 'Red'
                Muted = 'DarkGray'
                Border = 'DarkCyan'
                MenuNumber = 'Cyan'
            }
        }

        'DarkBlue' {
            $theme = [pscustomobject]@{
                Background = 'DarkBlue'
                Text = 'White'
                Title = 'Cyan'
                Accent = 'Yellow'
                Success = 'Green'
                Warning = 'DarkYellow'
                Error = 'Red'
                Muted = 'Gray'
                Border = 'Cyan'
                MenuNumber = 'Yellow'
            }
        }

        'GreenTerminal' {
            $theme = [pscustomobject]@{
                Background = 'Black'
                Text = 'Gray'
                Title = 'Green'
                Accent = 'Green'
                Success = 'Green'
                Warning = 'Yellow'
                Error = 'Red'
                Muted = 'DarkGreen'
                Border = 'DarkGreen'
                MenuNumber = 'Green'
            }
        }

        'Amber' {
            $theme = [pscustomobject]@{
                Background = 'Black'
                Text = 'Gray'
                Title = 'Yellow'
                Accent = 'DarkYellow'
                Success = 'Green'
                Warning = 'Yellow'
                Error = 'Red'
                Muted = 'DarkGray'
                Border = 'DarkYellow'
                MenuNumber = 'Yellow'
            }
        }

        'SCADA' {
            $theme = [pscustomobject]@{
                Background = 'Black'
                Text = 'White'
                Title = 'Cyan'
                Accent = 'Cyan'
                Success = 'Green'
                Warning = 'Yellow'
                Error = 'Red'
                Muted = 'DarkGray'
                Border = 'Blue'
                MenuNumber = 'Cyan'
            }
        }

        default {
            throw "Неизвестная тема '$Name'."
        }
    }

    Set-ThemeVariables -Theme $theme
    Apply-ConsoleTheme
    Save-CurrentTheme
}

function Select-ThemeColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    while ($true) {
        Show-Header
        Write-Color -Text $Title -Color $ThemeAccent
        Write-Host ''

        $colors = @(Get-AvailableThemeColors)

        for ($index = 0; $index -lt $colors.Count; $index++) {
            Write-Color `
                -Text ('  {0,2}. ' -f ($index + 1)) `
                -Color $ThemeMenuNumber `
                -NoNewline

            Write-Color `
                -Text $colors[$index] `
                -Color $colors[$index]
        }

        Write-Host ''
        Write-Color -Text '   0. Назад' -Color $ThemeMenuNumber

        $selection = (Read-Host 'Выберите цвет').Trim()

        if ($selection -eq '0') {
            return
        }

        $number = 0

        if (
            [int]::TryParse($selection, [ref]$number) -and
            $number -ge 1 -and
            $number -le $colors.Count
        ) {
            Set-Variable `
                -Name $VariableName `
                -Value $colors[$number - 1] `
                -Scope Script

            Apply-ConsoleTheme
            Save-CurrentTheme
            return
        }

        Write-Color -Text 'Неверный номер цвета.' -Color $ThemeError
        Start-Sleep -Milliseconds 800
    }
}

function Show-ThemeMenu {
    :ThemeLoop while ($true) {
        Show-Header
        Write-Color -Text 'Настройка интерфейса' -Color $ThemeAccent
        Write-Host ''

        Write-Color -Text '   1. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Фон окна                 [$ThemeBackground]" -Color $ThemeText

        Write-Color -Text '   2. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Основной текст           [$ThemeText]" -Color $ThemeText

        Write-Color -Text '   3. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Логотип                  [$ThemeTitle]" -Color $ThemeText

        Write-Color -Text '   4. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Акцент / заголовки       [$ThemeAccent]" -Color $ThemeText

        Write-Color -Text '   5. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Успех / Up               [$ThemeSuccess]" -Color $ThemeText

        Write-Color -Text '   6. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Предупреждения           [$ThemeWarning]" -Color $ThemeText

        Write-Color -Text '   7. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Ошибки / Disconnected    [$ThemeError]" -Color $ThemeText

        Write-Color -Text '   8. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Второстепенный текст     [$ThemeMuted]" -Color $ThemeText

        Write-Color -Text '   9. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Разделительные линии     [$ThemeBorder]" -Color $ThemeText

        Write-Color -Text '  10. ' -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text "Номера меню              [$ThemeMenuNumber]" -Color $ThemeText

        Write-Host ''
        Write-Color -Text '  20. Готовая тема: Classic' -Color $ThemeMenuNumber
        Write-Color -Text '  21. Готовая тема: Dark Blue' -Color $ThemeMenuNumber
        Write-Color -Text '  22. Готовая тема: Green Terminal' -Color $ThemeMenuNumber
        Write-Color -Text '  23. Готовая тема: Amber' -Color $ThemeMenuNumber
        Write-Color -Text '  24. Готовая тема: SCADA' -Color $ThemeMenuNumber
        Write-Color -Text '   0. Назад' -Color $ThemeMenuNumber

        Write-Host ''
        $selection = (Read-Host 'Выберите пункт').Trim()

        switch ($selection) {
            '0'  { break ThemeLoop }
            '1'  { Select-ThemeColor -Title 'Цвет фона' -VariableName 'ThemeBackground' }
            '2'  { Select-ThemeColor -Title 'Основной цвет текста' -VariableName 'ThemeText' }
            '3'  { Select-ThemeColor -Title 'Цвет логотипа' -VariableName 'ThemeTitle' }
            '4'  { Select-ThemeColor -Title 'Цвет акцента' -VariableName 'ThemeAccent' }
            '5'  { Select-ThemeColor -Title 'Цвет успешных операций' -VariableName 'ThemeSuccess' }
            '6'  { Select-ThemeColor -Title 'Цвет предупреждений' -VariableName 'ThemeWarning' }
            '7'  { Select-ThemeColor -Title 'Цвет ошибок' -VariableName 'ThemeError' }
            '8'  { Select-ThemeColor -Title 'Цвет второстепенного текста' -VariableName 'ThemeMuted' }
            '9'  { Select-ThemeColor -Title 'Цвет разделителей' -VariableName 'ThemeBorder' }
            '10' { Select-ThemeColor -Title 'Цвет номеров меню' -VariableName 'ThemeMenuNumber' }
            '20' { Set-BuiltInTheme -Name 'Classic' }
            '21' { Set-BuiltInTheme -Name 'DarkBlue' }
            '22' { Set-BuiltInTheme -Name 'GreenTerminal' }
            '23' { Set-BuiltInTheme -Name 'Amber' }
            '24' { Set-BuiltInTheme -Name 'SCADA' }
            default {
                Write-Color -Text 'Такого пункта нет.' -Color $ThemeError
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Test-IPv4AddressText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $address = $null

    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) {
        return $false
    }

    return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-SubnetMaskText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if (-not (Test-IPv4AddressText -Value $Value)) {
        return $false
    }

    $bytes = $Value.Split('.') | ForEach-Object { [int]$_ }
    $bits = ($bytes | ForEach-Object {
        [Convert]::ToString($_, 2).PadLeft(8, '0')
    }) -join ''

    return $bits -match '^1*0*$'
}


function Test-WizardCancelInput {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()

    return $normalized -in @(
        'exit',
        'cancel'
    )
}

function Show-WizardCancelled {
    Write-Host ''
    Write-Color `
        -Text 'Создание профиля отменено. Изменения не сохранены.' `
        -Color $ThemeWarning
    Start-Sleep -Milliseconds 800
}

function Read-RequiredIPv4 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [switch]$AllowCancel
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim()

        if ($AllowCancel -and (Test-WizardCancelInput -Value $value)) {
            $script:WizardCancelRequested = $true
            return $null
        }

        if (Test-IPv4AddressText -Value $value) {
            return $value
        }

        Write-Color -Text 'Некорректный IPv4-адрес.' -Color $ThemeError
    }
}

function Read-SubnetMask {
    param(
        [switch]$AllowCancel,

        [string]$DefaultMask = '255.255.255.0'
    )

    while ($true) {
        $value = (Read-Host ("Маска (Enter = {0}; можно /24 или 24)" -f $DefaultMask)).Trim()

        if ($AllowCancel -and (Test-WizardCancelInput -Value $value)) {
            $script:WizardCancelRequested = $true
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultMask
        }

        if ($value -match '^/?(\d{1,2})$') {
            $prefix = [int]$Matches[1]
            if ($prefix -ge 0 -and $prefix -le 32) {
                return Convert-PrefixToMask -PrefixLength $prefix
            }
        }

        if (Test-SubnetMaskText -Value $value) {
            return $value
        }

        Write-Color -Text 'Некорректная маска. Укажите 255.255.255.0, /24 или 24.' -Color $ThemeError
    }
}

function Read-OptionalGateway {
    param(
        [switch]$AllowCancel
    )

    while ($true) {
        $value = (Read-Host 'Шлюз (Enter = без шлюза)').Trim()

        if ($AllowCancel -and (Test-WizardCancelInput -Value $value)) {
            $script:WizardCancelRequested = $true
            return ''
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            return ''
        }

        if (Test-IPv4AddressText -Value $value) {
            return $value
        }

        Write-Color -Text 'Некорректный IPv4-адрес шлюза.' -Color $ThemeError
    }
}

function Read-OptionalVlan {
    param(
        [switch]$AllowCancel
    )

    while ($true) {
        $value = (Read-Host 'VLAN (Enter = без VLAN)').Trim()

        if ($AllowCancel -and (Test-WizardCancelInput -Value $value)) {
            $script:WizardCancelRequested = $true
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        $number = 0

        if (
            [int]::TryParse($value, [ref]$number) -and
            $number -ge 1 -and
            $number -le 4094
        ) {
            return $number
        }

        Write-Color -Text 'VLAN должен быть числом от 1 до 4094.' -Color $ThemeError
    }
}

function Save-Profiles {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles,

        [Parameter(Mandatory = $false)]
        [string]$Path = $script:CurrentProfilesPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Не выбран объект для сохранения профилей.'
    }

    $backupPath = "$Path.bak"

    if (Test-Path -LiteralPath $Path) {
        Copy-Item `
            -LiteralPath $Path `
            -Destination $backupPath `
            -Force
    }

    $Profiles |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $Path `
            -Encoding UTF8
}


function Invoke-BeskarPing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return
    }

    Show-Header
    Write-Color -Text 'PING' -Color $ThemeAccent
    Write-Host ''
    Write-Color -Text '  Узел    : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $Target -Color $ThemeText
    Write-Color -Text '  Пакетов : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text ([string]$PingCount) -Color $ThemeText
    Write-Color -Text '  Таймаут : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text ("{0} мс" -f $PingTimeout) -Color $ThemeText
    Write-Line
    Write-Host ''

    & ping.exe -n $PingCount -w $PingTimeout $Target
    $pingExitCode = $LASTEXITCODE

    Write-Host ''
    Write-Line

    if ($pingExitCode -eq 0) {
        Write-Color -Text 'Узел отвечает.' -Color $ThemeSuccess
        $logResult = 'Success'
    }
    else {
        Write-Color -Text 'Ответ от узла не получен.' -Color $ThemeError
        $logResult = 'NoReply'
    }

    Write-OperationLog `
        -Action 'Ping' `
        -Result $logResult `
        -Details "Target=$Target"

    Pause-Menu
}

function Start-PingWizard {
    Show-Header
    Write-Color -Text 'PING' -Color $ThemeAccent
    Write-Host ''
    Write-Color -Text 'Введите IPv4 или имя узла.' -Color $ThemeMuted
    Write-Color -Text 'Пример: 192.168.218.2 или plc-01' -Color $ThemeMuted
    Write-Host ''

    $target = (Read-Host 'Узел').Trim()

    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Color -Text 'Проверка отменена.' -Color $ThemeWarning
        Start-Sleep -Milliseconds 700
        return
    }

    Invoke-BeskarPing -Target $target
}


function Show-EditableProfileSummary {
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    $mode = Get-ProfileMode -Profile $Profile

    Write-Color -Text '  Название   : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text ([string]$Profile.Name) -Color $ThemeText
    Write-Color -Text '  Mode       : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $mode -Color $ThemeText
    Write-Color -Text '  Категория  : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $(if ($Profile.PSObject.Properties.Name -contains 'Category') { [string]$Profile.Category } else { 'Сетевые профили' }) -Color $ThemeText

    if ($mode -eq 'Network') {
        $vlanText = if (
            $Profile.PSObject.Properties.Name -contains 'VLAN' -and
            $null -ne $Profile.VLAN
        ) { [string]$Profile.VLAN } else { 'без VLAN' }

        Write-Color -Text '  VLAN       : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $vlanText -Color $ThemeText
        Write-Color -Text '  IP         : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text ($(if ([string]::IsNullOrWhiteSpace([string]$Profile.IP)) {'не задан'} else {$Profile.IP})) -Color $ThemeText
        Write-Color -Text '  Маска      : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text ($(if ([string]::IsNullOrWhiteSpace([string]$Profile.Mask)) {'не задана'} else {$Profile.Mask})) -Color $ThemeText

        $gatewayText = if (
            $Profile.PSObject.Properties.Name -contains 'Gateway' -and
            -not [string]::IsNullOrWhiteSpace([string]$Profile.Gateway)
        ) { [string]$Profile.Gateway } else { 'не задан' }

        Write-Color -Text '  Шлюз       : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $gatewayText -Color $ThemeText
    }

    if ($mode -in @('MultiAddress', 'Mixed')) {
        Write-Color -Text '  IP-адресов: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text (@($Profile.Addresses).Count) -Color $ThemeText
    }

    if ($mode -in @('Routes', 'Mixed')) {
        Write-Color -Text '  Маршрутов : ' -Color $ThemeMuted -NoNewline
        Write-Color -Text (@($Profile.Routes).Count) -Color $ThemeText
        Write-Color -Text '  Постоянные: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $(if ($Profile.Persistent) { 'да' } else { 'нет' }) -Color $ThemeText
    }

    Write-Color -Text '  DeviceName : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $(if ($Profile.PSObject.Properties.Name -contains 'DeviceName') { [string]$Profile.DeviceName } else { '' }) -Color $ThemeText

    Write-Color -Text '  PingTarget : ' -Color $ThemeMuted -NoNewline
    Write-Color -Text $(if ($Profile.PSObject.Properties.Name -contains 'PingTarget') { [string]$Profile.PingTarget } else { '' }) -Color $ThemeText
}

function Edit-NetworkProfileInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles,

        [Parameter(Mandatory = $true)]
        [int]$ProfileIndex
    )

    if ($ProfileIndex -lt 0 -or $ProfileIndex -ge $Profiles.Count) {
        Write-Color -Text 'Профиль не найден.' -Color $ThemeError
        Pause-Menu
        return $Profiles
    }

    $profile = $Profiles[$ProfileIndex]
    $mode = Get-ProfileMode -Profile $profile

    if ($mode -ne 'Network') {
        Show-Header
        Write-Color -Text 'Редактирование профиля' -Color $ThemeAccent
        Write-Host ''
        Write-Color -Text 'Пока через интерфейс редактируются только профили Mode=Network.' -Color $ThemeWarning
        Write-Color -Text ("Профиль '{0}' имеет Mode={1}." -f $profile.Name, $mode) -Color $ThemeMuted
        Pause-Menu
        return $Profiles
    }

    $edited = [pscustomobject][ordered]@{
        Name = [string]$profile.Name
        Category = if ($profile.PSObject.Properties.Name -contains 'Category') { [string]$profile.Category } else { 'Сетевые профили' }
        Mode = 'Network'
        VLAN = if ($profile.PSObject.Properties.Name -contains 'VLAN') { $profile.VLAN } else { $null }
        IP = [string]$profile.IP
        Mask = [string]$profile.Mask
        Gateway = if ($profile.PSObject.Properties.Name -contains 'Gateway') { [string]$profile.Gateway } else { '' }
        DeviceName = if ($profile.PSObject.Properties.Name -contains 'DeviceName') { [string]$profile.DeviceName } else { '' }
        PingTarget = if ($profile.PSObject.Properties.Name -contains 'PingTarget') { [string]$profile.PingTarget } else { '' }
    }

    while ($true) {
        Show-Header
        Write-Color -Text 'Редактирование профиля' -Color $ThemeAccent
        Write-Color -Text ("Объект: {0}" -f $script:CurrentObjectName) -Color $ThemeMuted
        Write-Host ''
        Show-EditableProfileSummary -Profile $edited
        Write-Host ''
        Write-Line
        Write-Color -Text '   1. Название' -Color $ThemeMenuNumber
        Write-Color -Text '   2. Категория' -Color $ThemeMenuNumber
        Write-Color -Text '   3. VLAN' -Color $ThemeMenuNumber
        Write-Color -Text '   4. IP' -Color $ThemeMenuNumber
        Write-Color -Text '   5. Маска' -Color $ThemeMenuNumber
        Write-Color -Text '   6. Шлюз' -Color $ThemeMenuNumber
        Write-Color -Text '   7. DeviceName' -Color $ThemeMenuNumber
        Write-Color -Text '   8. PingTarget' -Color $ThemeMenuNumber
        Write-Color -Text '  90. Сохранить изменения' -Color $ThemeSuccess
        Write-Color -Text '   0. Отмена' -Color $ThemeMenuNumber
        Write-Line

        $choice = (Read-Host 'Что изменить').Trim()

        switch ($choice) {
            '0' { return $Profiles }
            '1' {
                $value = (Read-Host 'Новое название').Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) { $edited.Name = $value }
            }
            '2' {
                $value = (Read-Host 'Новая категория (Enter = Сетевые профили)').Trim()
                $edited.Category = if ([string]::IsNullOrWhiteSpace($value)) { 'Сетевые профили' } else { $value }
            }
            '3' { $edited.VLAN = Read-OptionalVlan }
            '4' { $edited.IP = Read-RequiredIPv4 -Prompt 'Новый IP' }
            '5' { $edited.Mask = Read-SubnetMask }
            '6' { $edited.Gateway = Read-OptionalGateway }
            '7' { $edited.DeviceName = (Read-Host 'DeviceName (Enter = очистить)').Trim() }
            '8' {
                $value = (Read-Host 'PingTarget (Enter = очистить)').Trim()
                if (-not [string]::IsNullOrWhiteSpace($value) -and -not (Test-IPv4AddressText -Value $value)) {
                    Write-Color -Text 'Некорректный PingTarget.' -Color $ThemeError
                    Start-Sleep -Milliseconds 800
                }
                else { $edited.PingTarget = $value }
            }
            '90' {
                Show-Header
                Write-Color -Text 'Подтверждение изменений' -Color $ThemeAccent
                Write-Host ''
                Write-Color -Text 'Было:' -Color $ThemeMuted
                Show-EditableProfileSummary -Profile $profile
                Write-Host ''
                Write-Color -Text 'Стало:' -Color $ThemeSuccess
                Show-EditableProfileSummary -Profile $edited
                Write-Host ''

                $confirm = (Read-Host 'Сохранить? [Y/N]').Trim().ToLowerInvariant()
                if ($confirm -in @('y','yes','д','да')) {
                    $updated = @($Profiles)
                    $updated[$ProfileIndex] = $edited
                    Save-Profiles -Profiles $updated

                    Write-OperationLog -Action 'EditProfile' -Result 'Success' -Details "Object=$script:CurrentObjectName; Profile=$($edited.Name)"
                    Write-Host ''
                    Write-Color -Text 'Профиль сохранён.' -Color $ThemeSuccess
                    Write-Color -Text ('Резервная копия: {0}.bak' -f $script:CurrentProfilesPath) -Color $ThemeMuted
                    Pause-Menu
                    return @($updated)
                }
            }
            default {
                Write-Color -Text 'Такого пункта нет.' -Color $ThemeError
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Start-EditProfileWizard {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles,

        [Parameter(Mandatory = $false)]
        [Nullable[int]]$RequestedNumber = $null
    )

    if ($Profiles.Count -eq 0) {
        Show-Header
        Write-Color -Text 'В текущем объекте нет профилей.' -Color $ThemeWarning
        Pause-Menu
        return $Profiles
    }

    if ($null -ne $RequestedNumber) {
        return @(Edit-NetworkProfileInteractive -Profiles $Profiles -ProfileIndex ($RequestedNumber.Value - 1))
    }

    Show-Header
    Write-Color -Text 'Редактирование профилей' -Color $ThemeAccent
    Write-Color -Text ("Объект: {0}" -f $script:CurrentObjectName) -Color $ThemeMuted
    Write-Host ''

    $maxNameLength = ($Profiles | ForEach-Object { ([string]$_.Name).Length } | Measure-Object -Maximum).Maximum
    if ($maxNameLength -lt 12) { $maxNameLength = 12 }

    for ($index = 0; $index -lt $Profiles.Count; $index++) {
        $name = ([string]$Profiles[$index].Name).PadRight($maxNameLength)
        $summary = Get-ProfileSummary -Profile $Profiles[$index]
        Write-Color -Text ('  {0,2}. ' -f ($index + 1)) -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text $name -Color $ThemeText -NoNewline
        Write-Color -Text ('  {0}' -f $summary) -Color $ThemeMuted
    }

    Write-Host ''
    Write-Color -Text '   0. Назад' -Color $ThemeMenuNumber
    $selection = (Read-Host 'Выберите профиль').Trim()

    if ($selection -eq '0') { return $Profiles }

    $number = 0
    if ([int]::TryParse($selection,[ref]$number) -and $number -ge 1 -and $number -le $Profiles.Count) {
        return @(Edit-NetworkProfileInteractive -Profiles $Profiles -ProfileIndex ($number - 1))
    }

    Write-Color -Text 'Такого профиля нет.' -Color $ThemeError
    Pause-Menu
    return $Profiles
}


function Show-DeviceNameMenu {

    while ($true) {

        Show-Header

        Write-Color -Text 'Настройка отображения DeviceName' -Color $ThemeAccent
        Write-Host ''

        Write-Color -Text 'DeviceName — необязательное поле профиля.' -Color $ThemeMuted
        Write-Color -Text 'Оно позволяет показывать название подключаемого устройства' -Color $ThemeMuted
        Write-Color -Text 'при применении сетевого профиля.' -Color $ThemeMuted
        Write-Host ''

        $state = if ($ShowDeviceInfo) { 'ВКЛ' } else { 'ВЫКЛ' }

        Write-Color -Text 'Текущее состояние: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $state -Color $ThemeText

        Write-Host ''
        Write-Color -Text '1. Включить отображение' -Color $ThemeMenuNumber
        Write-Color -Text '2. Выключить отображение' -Color $ThemeMenuNumber
        Write-Color -Text '0. Назад' -Color $ThemeMenuNumber

        $choice=(Read-Host 'Выберите действие').Trim()

        switch ($choice) {
            '1' { $script:ShowDeviceInfo=$true }
            '2' { $script:ShowDeviceInfo=$false }
            '0' { return }
        }
    }
}

function Show-PingTargetMenu {

    while ($true) {

        Show-Header

        Write-Color -Text 'Настройка автоматической проверки связи' -Color $ThemeAccent
        Write-Host ''

        Write-Color -Text 'PingTarget позволяет после применения профиля' -Color $ThemeMuted
        Write-Color -Text 'проверять доступность адреса, указанного в профиле.' -Color $ThemeMuted
        Write-Host ''

        $state = if ($EnablePing) { 'ВКЛ' } else { 'ВЫКЛ' }

        Write-Color -Text 'Текущее состояние: ' -Color $ThemeMuted -NoNewline
        Write-Color -Text $state -Color $ThemeText

        Write-Host ''
        Write-Color -Text '1. Включить проверку' -Color $ThemeMenuNumber
        Write-Color -Text '2. Выключить проверку' -Color $ThemeMenuNumber
        Write-Color -Text '0. Назад' -Color $ThemeMenuNumber

        $choice = (Read-Host 'Выберите действие').Trim()

        switch ($choice) {
            '1' {
                $script:EnablePing = $true
            }
            '2' {
                $script:EnablePing = $false
            }
            '0' {
                return
            }
        }
    }
}

function Select-NewProfileMode {
    while ($true) {
        Write-Color -Text 'Выберите режим профиля:' -Color $ThemeAccent
        Write-Color -Text '  1. Network      — один постоянный IPv4, при необходимости VLAN и шлюз' -Color $ThemeText
        Write-Color -Text '  2. MultiAddress — несколько временных IPv4 на одном адаптере' -Color $ThemeText
        Write-Color -Text '  3. Routes       — временные или постоянные маршруты' -Color $ThemeText
        Write-Color -Text '  4. Mixed        — несколько IPv4 и маршруты' -Color $ThemeText
        Write-Color -Text '  0. Отмена' -Color $ThemeMenuNumber

        $choice = (Read-Host 'Режим').Trim().ToLowerInvariant()

        switch ($choice) {
            '0' { return $null }
            '1' { return 'Network' }
            '2' { return 'MultiAddress' }
            '3' { return 'Routes' }
            '4' { return 'Mixed' }
            'exit' { return $null }
            'cancel' { return $null }
            default { Write-Color -Text 'Введите номер от 0 до 4.' -Color $ThemeError }
        }
    }
}

function Read-NewProfileIdentity {
    while ($true) {
        $name = (Read-Host 'Название профиля').Trim()
        if (Test-WizardCancelInput -Value $name) { return $null }
        if (-not [string]::IsNullOrWhiteSpace($name)) { break }
        Write-Color -Text 'Название не может быть пустым.' -Color $ThemeError
    }

    Write-Host ''
    Write-Color -Text 'Категория — это только подпись-группа для списка профилей этого объекта.' -Color $ThemeMuted
    Write-Color -Text 'Она не изменяет IP, VLAN, маршруты или работу адаптера.' -Color $ThemeMuted
    Write-Color -Text 'Примеры: «ПНР», «Сервис», «Сетевые профили». Enter = «Сетевые профили».' -Color $ThemeMuted
    $category = (Read-Host 'Категория').Trim()
    if (Test-WizardCancelInput -Value $category) { return $null }
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Сетевые профили' }

    return [pscustomobject]@{ Name = $name; Category = $category }
}

function Read-EntryCount {
    param([string]$Label)

    while ($true) {
        $value = (Read-Host ("Количество {0} (1-20)" -f $Label)).Trim()
        if (Test-WizardCancelInput -Value $value) { return $null }
        $count = 0
        if ([int]::TryParse($value, [ref]$count) -and $count -ge 1 -and $count -le 20) {
            return $count
        }
        Write-Color -Text 'Введите целое число от 1 до 20.' -Color $ThemeError
    }
}

function Read-ProfileAddresses {
    $count = Read-EntryCount -Label 'IP-адресов'
    if ($null -eq $count) { return $null }
    $addresses = @()
    for ($index = 1; $index -le $count; $index++) {
        Write-Color -Text ("Адрес {0} из {1}" -f $index, $count) -Color $ThemeAccent
        $ip = Read-RequiredIPv4 -Prompt 'IP' -AllowCancel
        if ($script:WizardCancelRequested) { return $null }
        $mask = Read-SubnetMask -AllowCancel
        if ($script:WizardCancelRequested) { return $null }
        $addresses += [pscustomobject]@{ IP = $ip; Mask = $mask }
    }
    return @($addresses)
}

function Read-ProfileRoutes {
    $count = Read-EntryCount -Label 'маршрутов'
    if ($null -eq $count) { return $null }
    $routes = @()
    for ($index = 1; $index -le $count; $index++) {
        Write-Color -Text ("Маршрут {0} из {1}" -f $index, $count) -Color $ThemeAccent
        $destination = Read-RequiredIPv4 -Prompt 'Сеть назначения' -AllowCancel
        if ($script:WizardCancelRequested) { return $null }
        $mask = Read-SubnetMask -AllowCancel
        if ($script:WizardCancelRequested) { return $null }
        $gateway = Read-RequiredIPv4 -Prompt 'Шлюз' -AllowCancel
        if ($script:WizardCancelRequested) { return $null }
        $routes += [pscustomobject]@{ Destination = $destination; Mask = $mask; Gateway = $gateway }
    }
    return @($routes)
}

function Add-SpecialProfileInteractive {
    param([array]$Profiles, [string]$Mode)

    $identity = Read-NewProfileIdentity
    if ($null -eq $identity) { Show-WizardCancelled; return $Profiles }

    $profile = [ordered]@{ Name = $identity.Name; Category = $identity.Category; Mode = $Mode }

    if ($Mode -in @('MultiAddress', 'Mixed')) {
        $vlan = Read-OptionalVlan -AllowCancel
        if ($script:WizardCancelRequested) { Show-WizardCancelled; return $Profiles }
        $addresses = Read-ProfileAddresses
        if ($script:WizardCancelRequested -or $null -eq $addresses) { Show-WizardCancelled; return $Profiles }
        $profile.VLAN = $vlan
        $profile.Addresses = $addresses
    }

    if ($Mode -in @('Routes', 'Mixed')) {
        $routes = Read-ProfileRoutes
        if ($script:WizardCancelRequested -or $null -eq $routes) { Show-WizardCancelled; return $Profiles }
        $profile.Routes = $routes
        $persistent = (Read-Host 'Сохранять маршруты после перезагрузки? [y/N]').Trim().ToLowerInvariant()
        if (Test-WizardCancelInput -Value $persistent) { Show-WizardCancelled; return $Profiles }
        $profile.Persistent = $persistent -in @('y', 'yes', 'д', 'да')
    }

    $newProfile = [pscustomobject]$profile
    Write-Host ''
    Write-Color -Text 'Проверьте профиль перед сохранением:' -Color $ThemeAccent
    Show-EditableProfileSummary -Profile $newProfile
    $confirm = (Read-Host 'Сохранить профиль? [Y/N]').Trim().ToLowerInvariant()
    if ($confirm -notin @('y', 'yes', 'д', 'да')) { Show-WizardCancelled; return $Profiles }

    $updated = @($Profiles) + $newProfile
    Save-Profiles -Profiles $updated
    Write-OperationLog -Action 'AddProfile' -Result 'Success' -Details "Object=$script:CurrentObjectName; Profile=$($identity.Name); Mode=$Mode"
    Write-Color -Text 'Профиль сохранён.' -Color $ThemeSuccess
    Pause-Menu
    return @($updated)
}

function Add-NetworkProfileInteractive {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [array]$Profiles = @()
    )

    $script:WizardCancelRequested = $false

    Show-Header
    Write-Color -Text 'Добавление IP-профиля' -Color $ThemeAccent
    Write-Host ''

    Write-Color -Text 'Сначала выберите, куда сохранить новый профиль.' -Color $ThemeMuted
    Write-Host ''

    Write-Color -Text '   1. ' -Color $ThemeMenuNumber -NoNewline
    Write-Color `
        -Text ('Текущий объект: {0}' -f `
            $(if ([string]::IsNullOrWhiteSpace($script:CurrentObjectName)) {
                'не выбран'
            } else {
                $script:CurrentObjectName
            })) `
        -Color $ThemeText

    Write-Color -Text '   2. ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Выбрать существующий объект' -Color $ThemeText

    Write-Color -Text '   3. ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Создать новый объект и добавить профиль в него' -Color $ThemeText

    Write-Color -Text '   0. ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'Отмена' -Color $ThemeText

    $destinationChoice = (Read-Host 'Выберите вариант').Trim()

    switch ($destinationChoice) {
        '0' {
            return $Profiles
        }

        '1' {
            if ([string]::IsNullOrWhiteSpace($script:CurrentProfilesPath)) {
                Write-Color -Text 'Текущий объект не выбран.' -Color $ThemeWarning
                Pause-Menu
                return $Profiles
            }
        }

        '2' {
            if (-not (Select-ObjectMenu)) {
                return $Profiles
            }
        }

        '3' {
            if (-not (Select-ObjectMenu -AllowCreate)) {
                return $Profiles
            }
        }

        default {
            Write-Color -Text 'Неверный вариант.' -Color $ThemeError
            Pause-Menu
            return $Profiles
        }
    }

    $Profiles = @(Get-Profiles)

    Show-Header
    Write-Color -Text 'Добавление сетевого профиля' -Color $ThemeAccent
    Write-Color -Text ('Объект: {0}' -f $script:CurrentObjectName) -Color $ThemeSuccess
    Write-Host ''

    $mode = Select-NewProfileMode
    if ($null -eq $mode) {
        Show-WizardCancelled
        return $Profiles
    }

    if ($mode -ne 'Network') {
        return Add-SpecialProfileInteractive -Profiles $Profiles -Mode $mode
    }

    Show-Header
    Write-Color -Text 'Добавление профиля Network' -Color $ThemeAccent
    Write-Color -Text ('Объект: {0}' -f $script:CurrentObjectName) -Color $ThemeSuccess
    Write-Host ''

    Write-Color -Text 'Этот мастер создаёт обычный профиль Network:' -Color $ThemeMuted
    Write-Color -Text 'VLAN (при необходимости) + один статический IPv4 + маска + шлюз.' -Color $ThemeMuted
    Write-Color -Text 'На любом шаге введите exit или cancel для выхода без сохранения.' -Color $ThemeWarning
    Write-Host ''

    Write-Color -Text 'Шаг 1/7 — Название профиля' -Color $ThemeAccent
    Write-Color -Text 'Пример: РП, ТП, Заводской МИП.' -Color $ThemeMuted

    do {
        $name = (Read-Host 'Название профиля').Trim()

        if (Test-WizardCancelInput -Value $name) {
            Show-WizardCancelled
            return $Profiles
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Color -Text 'Название не может быть пустым.' -Color $ThemeError
        }
    } while ([string]::IsNullOrWhiteSpace($name))

    Write-Host ''
    Write-Color -Text 'Шаг 2/7 — Категория' -Color $ThemeAccent
    Write-Color -Text 'Это подпись-группа для списка профилей этого объекта; на настройки она не влияет.' -Color $ThemeMuted
    Write-Color -Text 'Примеры: «ПНР», «Сервис», «Сетевые профили». Enter = «Сетевые профили».' -Color $ThemeMuted

    $category = (Read-Host 'Категория').Trim()

    if (Test-WizardCancelInput -Value $category) {
        Show-WizardCancelled
        return $Profiles
    }

    if ([string]::IsNullOrWhiteSpace($category)) {
        $category = 'Сетевые профили'
    }

    Write-Host ''
    Write-Color -Text 'Шаг 3/7 — VLAN' -Color $ThemeAccent
    Write-Color -Text 'Введите 1–4094 или Enter, если VLAN не нужен.' -Color $ThemeMuted
    $vlan = Read-OptionalVlan -AllowCancel

    if ($script:WizardCancelRequested) {
        Show-WizardCancelled
        return $Profiles
    }

    Write-Host ''
    Write-Color -Text 'Шаг 4/7 — IP-адрес ноутбука' -Color $ThemeAccent
    Write-Color -Text 'Пример: 192.168.218.208' -Color $ThemeMuted
    $ip = Read-RequiredIPv4 -Prompt 'IP' -AllowCancel

    if ($script:WizardCancelRequested) {
        Show-WizardCancelled
        return $Profiles
    }

    Write-Host ''
    Write-Color -Text 'Шаг 5/7 — Маска подсети' -Color $ThemeAccent
    Write-Color -Text 'Enter = стандартная 255.255.255.0. Можно 255.255.255.0, /24 или 24.' -Color $ThemeMuted
    $mask = Read-SubnetMask -AllowCancel

    if ($script:WizardCancelRequested) {
        Show-WizardCancelled
        return $Profiles
    }

    Write-Host ''
    Write-Color -Text 'Шаг 6/7 — Шлюз' -Color $ThemeAccent
    Write-Color -Text 'Enter = без шлюза.' -Color $ThemeMuted
    $gateway = Read-OptionalGateway -AllowCancel

    if ($script:WizardCancelRequested) {
        Show-WizardCancelled
        return $Profiles
    }

    Write-Host ''
    Write-Color -Text 'Шаг 7/7 — Дополнительные параметры' -Color $ThemeAccent
    $deviceName = (Read-Host 'Название устройства (Enter = пропустить)').Trim()

    if (Test-WizardCancelInput -Value $deviceName) {
        Show-WizardCancelled
        return $Profiles
    }

    $pingTarget = (Read-Host 'PingTarget (Enter = пропустить)').Trim()

    if (Test-WizardCancelInput -Value $pingTarget) {
        Show-WizardCancelled
        return $Profiles
    }

    if (
        -not [string]::IsNullOrWhiteSpace($pingTarget) -and
        -not (Test-IPv4AddressText -Value $pingTarget)
    ) {
        Write-Color -Text 'PingTarget некорректен — поле не будет сохранено.' -Color $ThemeWarning
        $pingTarget = ''
    }

    $newProfile = [ordered]@{
        Name = $name
        Category = $category
        Mode = 'Network'
        VLAN = $vlan
        IP = $ip
        Mask = $mask
        Gateway = $gateway
    }

    if (-not [string]::IsNullOrWhiteSpace($deviceName)) {
        $newProfile.DeviceName = $deviceName
    }

    if (-not [string]::IsNullOrWhiteSpace($pingTarget)) {
        $newProfile.PingTarget = $pingTarget
    }

    Write-Host ''
    Write-Line
    Write-Color -Text 'Проверьте профиль перед сохранением:' -Color $ThemeAccent
    Write-Color -Text ('  Объект   : {0}' -f $script:CurrentObjectName) -Color $ThemeText
    Write-Color -Text ('  Название : {0}' -f $name) -Color $ThemeText
    Write-Color -Text ('  Категория: {0}' -f $category) -Color $ThemeText
    Write-Color -Text ('  VLAN     : {0}' -f $(if ($null -eq $vlan) { 'без VLAN' } else { $vlan })) -Color $ThemeText
    Write-Color -Text ('  IP       : {0}' -f $ip) -Color $ThemeText
    Write-Color -Text ('  Маска    : {0}' -f $mask) -Color $ThemeText
    Write-Color -Text ('  Шлюз     : {0}' -f $(if ([string]::IsNullOrWhiteSpace($gateway)) { 'не задан' } else { $gateway })) -Color $ThemeText

    Write-Host ''
    $confirm = (Read-Host 'Сохранить профиль? [Y/N]').Trim().ToLowerInvariant()

    if (Test-WizardCancelInput -Value $confirm) {
        Show-WizardCancelled
        return $Profiles
    }

    if ($confirm -notin @('y', 'yes', 'д', 'да')) {
        Write-Color -Text 'Добавление отменено.' -Color $ThemeWarning
        Pause-Menu
        return $Profiles
    }

    $updated = @($Profiles) + [pscustomobject]$newProfile
    Save-Profiles -Profiles $updated

    Write-Host ''
    Write-Color `
        -Text ('Профиль сохранён в объект «{0}».' -f $script:CurrentObjectName) `
        -Color $ThemeSuccess

    Write-Color `
        -Text ('Резервная копия: {0}.bak' -f $script:CurrentProfilesPath) `
        -Color $ThemeMuted

    Write-OperationLog `
        -Action 'AddProfile' `
        -Result 'Success' `
        -Details "Object=$script:CurrentObjectName; Profile=$name; IP=$ip; VLAN=$vlan"

    Pause-Menu
    return @($updated)
}

function Show-CommandHelp {
    Show-Header
    Write-Color -Text 'Команды BESKAR' -Color $ThemeAccent
    Write-Host ''

    $helpCommands = @(
        @('ping',       'проверить доступность узла'),
        @('devicename', 'включить/отключить отображение DeviceName при применении профиля'),
        @('pingtarget', 'включить/отключить автоматическую проверку связи после применения профиля'),
        @('ping IP',    'сразу выполнить ping адреса или имени узла'),
        @('edit',       'редактировать профиль текущего объекта'),
        @('edit N',     'сразу открыть профиль N'),
        @('add ip',     'добавить обычный Network-профиль в JSON'),
        @('theme',      'настроить цвета интерфейса'),
        @('objects',    'вернуться к выбору объекта'),
        @('adapter',    'выбрать другой сетевой адаптер'),
        @('dhcp',       'снять VLAN/статику и включить DHCP'),
        @('state',      'обновить текущее состояние'),
        @('reboot',     'полностью перезапустить BESKAR'),
        @('help',       'показать эту справку'),
        @('exit',       'выход')
    )

    $helpCommandWidth = 11

    foreach ($item in $helpCommands) {
        $command = ([string]$item[0]).PadRight($helpCommandWidth)

        Write-Color -Text ("  {0}" -f $command) -Color $ThemeMenuNumber -NoNewline
        Write-Color -Text ("  {0}" -f [string]$item[1]) -Color $ThemeText
    }

    Write-Host ''
    Write-Color -Text 'Служебные номера' -Color $ThemeAccent
    Write-Host ''

    Write-Color -Text '  90  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'обновить состояние адаптера' -Color $ThemeText

    Write-Color -Text '  91  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'выбрать другой адаптер' -Color $ThemeText

    Write-Color -Text '  97  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'восстановить исходное состояние' -Color $ThemeText

    Write-Color -Text '  99  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'вернуть VLAN «отсутствует» и DHCP' -Color $ThemeText

    Write-Color -Text '   0  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'выход из программы' -Color $ThemeText

    Write-Host ''
    Write-Color -Text 'В меню theme пункт 0 возвращает в главное меню.' -Color $ThemeMuted
    Write-Color -Text 'Номера профилей продолжают работать как раньше.' -Color $ThemeMuted

    Write-Host ''
    Write-Color -Text 'Нажмите Enter, чтобы вернуться в главное меню...' -Color $ThemeMuted
    [void](Read-Host)

    return

    Write-Host ''
    Write-Color -Text 'Навигация в дополнительных меню' -Color $ThemeAccent
    Write-Host ''

    Write-Color -Text '  Меню адаптеров: ' -Color $ThemeMuted
    Write-Color -Text '    90  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'обновить список и состояние адаптеров' -Color $ThemeText
    Write-Color -Text '     0  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'выход из программы' -Color $ThemeText

    Write-Color -Text '  Меню объектов: ' -Color $ThemeMuted
    Write-Color -Text '    90  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'обновить список объектов' -Color $ThemeText
    Write-Color -Text '    91  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'создать новый объект' -Color $ThemeText
    Write-Color -Text '     0  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'выход из программы' -Color $ThemeText

    Write-Color -Text '  Внутри объекта: ' -Color $ThemeMuted
    Write-Color -Text '     0  ' -Color $ThemeMenuNumber -NoNewline
    Write-Color -Text 'назад к выбору объектов' -Color $ThemeText

}



function Set-BeskarConsoleSize {
    try {
        $raw = $Host.UI.RawUI

        # Ограничиваем запрошенный размер максимально доступным размером окна.
        $maxWindow = $raw.MaxPhysicalWindowSize

        $targetWidth = [Math]::Min(
            [Math]::Max(80, $ConsoleWindowWidth),
            $maxWindow.Width
        )

        $targetHeight = [Math]::Min(
            [Math]::Max(20, $ConsoleWindowHeight),
            $maxWindow.Height
        )

        # Сначала увеличиваем буфер. Он не может быть меньше текущего окна.
        $bufferWidth = [Math]::Max(
            $targetWidth,
            $raw.WindowSize.Width
        )

        $bufferHeight = [Math]::Max(
            $ConsoleBufferHeight,
            $targetHeight
        )

        $raw.BufferSize = New-Object `
            System.Management.Automation.Host.Size(
                $bufferWidth,
                $bufferHeight
            )

        # Затем устанавливаем видимый размер окна.
        $raw.WindowSize = New-Object `
            System.Management.Automation.Host.Size(
                $targetWidth,
                $targetHeight
            )
    }
    catch {
        # Windows Terminal и некоторые другие хосты могут игнорировать RawUI.
        # Ошибка размера не должна мешать запуску BESKAR.
    }
}

function Show-StartupAnimation {
    if (-not $EnableStartupAnimation) {
        return
    }

    try {
        Clear-Host

        $logo = @(
            '██████╗ ███████╗███████╗██╗  ██╗ █████╗ ██████╗',
            '██╔══██╗██╔════╝██╔════╝██║ ██╔╝██╔══██╗██╔══██╗',
            '██████╔╝█████╗  ███████╗█████╔╝ ███████║██████╔╝',
            '██╔══██╗██╔══╝  ╚════██║██╔═██╗ ██╔══██║██╔══██╗',
            '██████╔╝███████╗███████║██║  ██╗██║  ██║██║  ██║',
            '╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝'
        )

        Write-Host ''

        foreach ($line in $logo) {
            Write-Color -Text ('        ' + $line) -Color $ThemeTitle
            Start-Sleep -Milliseconds 55
        }

        Write-Host ''
        Write-Color -Text ('        ' + $AppName) -Color $ThemeText
        Write-Color -Text ('        Version ' + $AppVersion) -Color $ThemeMuted
        Write-Host ''

        $frames = @(
            '[■□□□□□□□□□]',
            '[■■□□□□□□□□]',
            '[■■■□□□□□□□]',
            '[■■■■□□□□□□]',
            '[■■■■■□□□□□]',
            '[■■■■■■□□□□]',
            '[■■■■■■■□□□]',
            '[■■■■■■■■□□]',
            '[■■■■■■■■■□]',
            '[■■■■■■■■■■]'
        )

        foreach ($frame in $frames) {
            Write-Host -NoNewline "`r        "
            Write-Host -NoNewline $frame -ForegroundColor ([ConsoleColor]$ThemeSuccess)
            Start-Sleep -Milliseconds 70
        }

        Write-Host ''
        Write-Host ''
        Write-Color -Text '        READY' -Color $ThemeSuccess
        Start-Sleep -Milliseconds 450
        Clear-Host
    }
    catch {
        # Анимация не должна мешать запуску основной программы.
        Clear-Host
    }
}


function Restart-Beskar {
    Write-OperationLog `
        -Action 'Reboot' `
        -Result 'Requested' `
        -Details 'Full script restart'

    try {
        $arguments = @(
            '-NoLogo'
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            ('"{0}"' -f $PSCommandPath)
        )

        Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $arguments

        exit
    }
    catch {
        Write-Color `
            -Text ('Не удалось перезапустить BESKAR: {0}' -f $_.Exception.Message) `
            -Color $ThemeError

        Pause-Menu
    }
}

function Start-Beskar {
    if (-not (Test-IsAdministrator)) {
        Restart-AsAdministrator
    }

    Load-SavedTheme
    Apply-ConsoleTheme
    Set-BeskarConsoleSize

    try {
        $host.UI.RawUI.WindowTitle = "$AppName v$AppVersion"
    }
    catch {
    }

    Show-StartupAnimation

    Ensure-ProfilesDirectory
    Select-NetworkAdapter

    if (-not (Select-ObjectMenu -AllowCreate)) {
        return
    }

    $profiles = @(Get-Profiles)

    :MainLoop while ($true) {
        try {
            Update-SelectedAdapterCapability
        }
        catch {
            Write-Color -Text $_.Exception.Message -Color $ThemeWarning
            Pause-Menu
            Select-NetworkAdapter
            continue MainLoop
        }
        Show-MainMenu -Profiles $profiles

        $selection = (Read-Host 'Введите номер профиля или команду').Trim()
        $command = $selection.ToLowerInvariant()

        switch ($command) {
            'exit' {
                break MainLoop
            }

            'quit' {
                break MainLoop
            }

            'help' {
                Show-CommandHelp
                continue MainLoop
            }

            'ping' {
                Start-PingWizard
                continue MainLoop
            }

            'pingtarget' {
                Show-PingTargetMenu
                continue MainLoop
            }

            'devicename' {
                Show-DeviceNameMenu
                continue MainLoop
            }

            'edit' {
                $profiles = @(Start-EditProfileWizard -Profiles $profiles)
                continue MainLoop
            }

            'theme' {
                Show-ThemeMenu
                continue MainLoop
            }

            'objects' {
                if (Select-ObjectMenu -AllowCreate) {
                    $profiles = @(Get-Profiles)
                }
                continue MainLoop
            }

            'back' {
                if (Select-ObjectMenu -AllowCreate) {
                    $profiles = @(Get-Profiles)
                }
                continue MainLoop
            }

            'adapter' {
                $script:AdapterCapability = $null
                $script:VlanProperty = $null
                Select-NetworkAdapter
                continue MainLoop
            }

            'dhcp' {
                Restore-Dhcp
                continue MainLoop
            }

            'state' {
                continue MainLoop
            }

            'reboot' {
                Restart-Beskar
                break MainLoop
            }

            'add ip' {
                $oldPath = $script:CurrentProfilesPath
                $profiles = @(
                    Add-NetworkProfileInteractive -Profiles $profiles
                )

                # Мастер может переключить объект назначения.
                if ($script:CurrentProfilesPath -ne $oldPath) {
                    $profiles = @(Get-Profiles)
                }

                continue MainLoop
            }
        }

        if ($command -match '^ping\s+(.+)$') {
            $target = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                Invoke-BeskarPing -Target $target
            }
            continue MainLoop
        }

        if ($command -match '^edit\s+(\d+)$') {
            $profileNumber = [int]$Matches[1]
            $profiles = @(Start-EditProfileWizard -Profiles $profiles -RequestedNumber $profileNumber)
            continue MainLoop
        }

        if ($selection -eq '0') {
            if (Select-ObjectMenu -AllowCreate) {
                $profiles = @(Get-Profiles)
                continue MainLoop
            }

            break MainLoop
        }

        if ($selection -eq '90') {
            continue MainLoop
        }

        if ($selection -eq '91') {
            Select-NetworkAdapter
            continue MainLoop
        }

        if ($selection -eq '97') {
            Restore-OriginalState
            continue MainLoop
        }

        if ($selection -eq '99') {
            Restore-Dhcp
            continue MainLoop
        }

        $number = 0

        if (
            [int]::TryParse($selection, [ref]$number) -and
            $script:MenuMap.ContainsKey($number)
        ) {
            Apply-Profile -Profile $script:MenuMap[$number]
            continue MainLoop
        }

        Write-Color -Text 'Такого профиля или команды нет. Введите help.' -Color $ThemeError
        Start-Sleep -Seconds 1
    }
}

try {
    Start-Beskar
}
catch {
    $message = @"
BESKAR Network Manager failed to start.

Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Exception: $($_.Exception.Message)

Full error:
$($_ | Out-String)
"@

    $message |
        Set-Content `
            -LiteralPath $StartupErrorLog `
            -Encoding UTF8

    Write-Host ''
    Write-Host 'КРИТИЧЕСКАЯ ОШИБКА ЗАПУСКА' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Подробности сохранены в:" -ForegroundColor Yellow
    Write-Host $StartupErrorLog -ForegroundColor Cyan
    Write-Host ''
    Read-Host 'Нажмите Enter для выхода'
    exit 1
}
