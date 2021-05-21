#Requires -Version 7.0 -RunAsAdministrator
#------------------------------------------------------------------------------
# FILE:         action.ps1
# CONTRIBUTOR:  Jeff Lill
# COPYRIGHT:    Copyright (c) 2005-2021 by neonFORGE LLC.  All rights reserved.
#
# The contents of this repository are for private use by neonFORGE, LLC. and may not be
# divulged or used for any purpose by other organizations or individuals without a
# formal written and signed agreement with neonFORGE, LLC.

# Verify that we're running on a properly configured neonFORGE jobrunner 
# and import the deployment and action scripts from neonCLOUD.

# NOTE: This assumes that the required [$NC_ROOT/Powershell/*.ps1] files
#       in the current clone of the repo on the runner are up-to-date
#       enough to be able to obtain secrets and use GitHub Action functions.
#       If this is not the case, you'll have to manually pull the repo 
#       first on the runner.

$ncRoot = $env:NC_ROOT

if ([System.String]::IsNullOrEmpty($ncRoot) -or ![System.IO.Directory]::Exists($ncRoot))
{
    throw "Runner Config: neonCLOUD repo is not present."
}

$ncPowershell = [System.IO.Path]::Combine($ncRoot, "Powershell")

Push-Location $ncPowershell
. ./includes.ps1
Pop-Location

# Fetch the inputs

$hostType     = Get-ActionInput "host-type"      $true
$baseImageUri = Get-ActionInput "base-image-uri" $true
$buildCommit  = Get-ActionInput "build-commit"   $true
$buildLogName = Get-ActionInput "build-log"      $true
$buildLogPath = [System.IO.Path]::Combine($env:GITHUB_WORKSPACE, $buildLogName)

$env:GITHUB_WORKSPACE = "C:\Temp\NodeImage"
#-------------------------------

# Initialize the outputs

Set-ActionOutput "success"   "true"
Set-ActionOutput "build-log" $buildLogPath

# Perform the operation

try
{
    # Validate the target host type and configure the node-image command options

    $targetFolder       = $env:GITHUB_WORKSPACE
    # $publishOption      = "--publish"
    $publishOption      = "--no-containers"
    $hostAddressOption  = ""
    $hostAccountOption  = ""
    $hostPasswordOption = ""
    $nodeAddressOption  = ""
    $nodeNameOption     = ""

    Switch ($hostType)
    {
        "wsl2"
        {
        }

        "hyperv"
        {
            $nodeAddressOption = "--node-address=10.0.1.10"     # <-- $todo(jefflill): needs to be read from neon-assistant profile
        }

        "xenserver"
        {
            throw "Not implemented"
        }

        "aws"
        {
            throw "Not implemented"
        }

        "azure"
        {
            throw "Not implemented"
        }

        default
        {
            throw "Unknown build target: $hostType"
        }
    }

    # Discard any neonCLOUD commits and then checkout the requested commit

    Push-Cwd $ncRoot

        git reset --quiet --hard
        ThrowOnExitCode
    
        git fetch --quiet
        ThrowOnExitCode

        git checkout --quiet --detach $buildCommit
        ThrowOnExitCode

    Pop-Cwd

    #--------------------------------------------------------------------------
    # Build neonCLOUD (including tools) so we can use the [neon-image] tool

    Write-Output ""                                                             > $buildLogPath
    Write-Output "===========================================================" >> $buildLogPath
    Write-Output "Building neonCLOUD (with tools)"                             >> $buildLogPath
    Write-Output "===========================================================" >> $buildLogPath
    Write-Output ""                                                            >> $buildLogPath

    $buildScript = [System.IO.Path]::Combine($env:NC_TOOLBIN, "neoncloud-builder.ps1")

    pwsh $buildScript -tools 2>&1 >> $buildLogPath
    ThrowOnExitCode

    #--------------------------------------------------------------------------
    # Build and publish the requested node image

    Write-Output ""                                                            >> $buildLogPath
    Write-Output "===========================================================" >> $buildLogPath
    Write-Output "Building [$hostType] node image"                             >> $buildLogPath
    Write-Output "===========================================================" >> $buildLogPath
    Write-Output ""                                                            >> $buildLogPath

    $neonImagePath = [System.IO.Path]::Combine($env:NC_BUILD, "neon-image", "neon-image.exe")

    # Remove any locally cached images

    $result = Invoke-CaptureStreams "$neonImagePath prepare clean" -interleave
    Write-Output $result.stdout >> $buildLogPath

    # Prepare the node image for the target environment

    $result = Invoke-CaptureStreams "$neonImagePath prepare node $hostType $targetFolder $baseImageUri $nodeAddressOption $hostAddressOption $hostAccountOption $hostPasswordOption $nodeNameOption $publishOption" -interleave
    Write-Output $result.stdout >> $buildLogPath
}
catch
{
    Write-ActionException $_
    Set-ActionOutput "success" "false"

    # Discard any neonCLOUD commits and checkout master 

    Push-Cwd $ncRoot

        git reset --quiet --hard
        ThrowOnExitCode
    
        git fetch --quiet
        ThrowOnExitCode

        git checkout --quiet master
        ThrowOnExitCode
    
        git pull --quiet
        ThrowOnExitCode

    Pop-Cwd

    exit 1
}
