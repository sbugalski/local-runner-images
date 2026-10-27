################################################################################
##  File:  Install-PowerShellModulesWithRetry.ps1
##  Desc:  Runs Install-PowerShellModules.ps1 and Install-PowerShellAzModules.ps1
##         of a local UTM build with a retry around every Install-Module,
##         Update-Module and Save-Module call. Since 2026-10-26 the PowerShell
##         Gallery fails random requests with 404
##         (https://github.com/PowerShell/PowerShellGallery/issues/356), and
##         Az and Microsoft.Graph pull about a hundred sub-modules each, so one
##         failed request ended almost every build.
##         Each call is wrapped in Invoke-WithGalleryRetry in the script text, as
##         ubicloud/runner-images does in its copy of these scripts. Packer
##         uploads the scripts to INSTALLER_SCRIPT_FOLDER beforehand, and
##         generate-template.sh puts this script in their place
################################################################################

$ErrorActionPreference = "Stop"

function Invoke-WithGalleryRetry([scriptblock] $ScriptBlock) {
    $attempts = 10
    $interval = 30
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -ge $attempts) {
                throw
            }
            Write-Warning "Attempt $attempt/$attempts failed, retrying in $interval seconds: $($_.Exception.Message)"
            Start-Sleep -Seconds $interval
        }
    }
}

$moduleCommand = '(?m)^(\s*)((?:Install|Update|Save)-Module\s.*?)\s*$'
foreach ($scriptName in "Install-PowerShellModules.ps1", "Install-PowerShellAzModules.ps1") {
    $script = Get-Content -Raw -Path (Join-Path $env:INSTALLER_SCRIPT_FOLDER $scriptName)
    if ($script -notmatch $moduleCommand) {
        throw "$scriptName has no module commands to retry, compare it with Install-PowerShellModulesWithRetry.ps1"
    }
    . ([scriptblock]::Create(($script -replace $moduleCommand, '$1Invoke-WithGalleryRetry { $2 }')))
}
