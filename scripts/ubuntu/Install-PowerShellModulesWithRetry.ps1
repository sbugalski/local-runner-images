################################################################################
##  File:  Install-PowerShellModulesWithRetry.ps1
##  Desc:  Runs Install-PowerShellModules.ps1 and Install-PowerShellAzModules.ps1
##         of a local UTM build with a retry around every PowerShell Gallery
##         call. The gallery answers a few percent of requests with 404, which
##         PowerShellGet reports as a missing package, and with dozens of
##         modules to install one such response ended almost every build.
##         generate-template.sh puts this script in place of the two scripts
##         and Packer uploads them to INSTALLER_SCRIPT_FOLDER beforehand
################################################################################

# Plain functions so that named arguments pass through @args unchanged
function Invoke-WithGalleryRetry($Command) {
    $attempts = 5
    for ($attempt = 1; ; $attempt++) {
        try {
            return & "PowerShellGet\$Command" @args -ErrorAction Stop
        } catch {
            if ($attempt -ge $attempts) {
                throw
            }
            Write-Warning "$Command failed (attempt $attempt of $attempts), retrying: $_"
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

# Functions take precedence over cmdlets of the same name, so the scripts
# dot-sourced below call these
function Install-Module { Invoke-WithGalleryRetry Install-Module @args }
function Update-Module { Invoke-WithGalleryRetry Update-Module @args }
function Save-Module { Invoke-WithGalleryRetry Save-Module @args }

. "$env:INSTALLER_SCRIPT_FOLDER/Install-PowerShellModules.ps1"
. "$env:INSTALLER_SCRIPT_FOLDER/Install-PowerShellAzModules.ps1"
