$ErrorActionPreference = "Stop"

function Validate-Scripts {
    Param (
        [Parameter(Mandatory=$true)]
        [string[]]$Path,
        [Parameter(Mandatory=$true)]
        [string]$ExpectedShebang
    )
    $ScriptWithoutShebangLine = @()
    Get-ChildItem $path -Recurse -File -Filter "*.sh" | ForEach-Object {
        $relativePath = Resolve-Path $_.FullName -Relative
        $shebangLine = Get-Content -Path $_.FullName | Select-Object -First 1
        if ($shebangLine -eq $ExpectedShebang) {
            Write-Host "[+] '$relativePath'"
        }
        else {
            Write-Host "[-] '$relativePath'"
            $ScriptWithoutShebangLine += $relativePath
        }
    }
    return $ScriptWithoutShebangLine
}

# Scripts that run on a macOS host (UTM builds) follow the macOS convention,
# except the Ubuntu ones, which also run on Linux in CI
$PathUbuntu = @("./images/ubuntu/scripts", "./scripts/ubuntu", "./scripts/ubuntu-slim")
$PathMacOS = @("./images/macos", "./scripts/macos", "./scripts/run-ephemeral-runner.sh", "./helpers/utm")
$PatternUbuntu = "#!/bin/bash -e"
$PatternMacOS = "#!/bin/bash -e -o pipefail"
$ScriptsWithBrokenShebang = @()
$ScriptsWithBrokenShebang += Validate-Scripts -Path $PathUbuntu -ExpectedShebang $PatternUbuntu
$ScriptsWithBrokenShebang += Validate-Scripts -Path $PathMacOS -ExpectedShebang $PatternMacOS
if ($ScriptsWithBrokenShebang.Length -gt 0) {
    Write-Host "`n`n`n##[error] The following scripts have incorrect shebang:"
    $ScriptsWithBrokenShebang | ForEach-Object {
        Write-Host "##[error] '$_'"
    }
    Write-Host "`n`n##[error] Expected shebang for scripts in '$($PathUbuntu -join "', '")' folders is '$PatternUbuntu'"
    Write-Host "##[error] Expected shebang for scripts in '$($PathMacOS -join "', '")' folders is '$PatternMacOS'"
    exit 1
    else {
        Write-Host "All scripts have correct shebang."
    }
}
