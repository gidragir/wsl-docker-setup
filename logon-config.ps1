#Requires -RunAsAdministrator

$cfgFile = "$env:TEMP\secpol.inf"
$dbFile = "$env:TEMP\secpol.sdb"
# SID для системной группы NT VIRTUAL MACHINE\Virtual Machines
$targetSid = "*S-1-5-83-0" 

secedit /export /cfg $cfgFile /areas USER_RIGHTS | Out-Null
$config = Get-Content $cfgFile -Encoding Unicode

$rightsToGrant = @("SeBatchLogonRight", "SeServiceLogonRight")

foreach ($right in $rightsToGrant) {
    $match = $config -match "^$right\s*="
    if ($match) {
        $lineIndex = [array]::IndexOf($config, $match[0])
        if (-not $config[$lineIndex].Contains($targetSid)) {
            $config[$lineIndex] += ",$targetSid"
        }
    } else {
        $privIndex = [array]::IndexOf($config, "[Privilege Rights]")
        if ($privIndex -ge 0) {
            $config = $config[0..$privIndex] + "$right = $targetSid" + $config[($privIndex+1)..($config.Length-1)]
        }
    }
}

$config | Set-Content $cfgFile -Encoding Unicode
secedit /configure /db $dbFile /cfg $cfgFile /areas USER_RIGHTS | Out-Null

Remove-Item $cfgFile, $dbFile -ErrorAction SilentlyContinue
Write-Host "Права обновлены. Выполните перезагрузку системы."