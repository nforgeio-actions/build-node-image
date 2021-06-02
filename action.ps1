#Requires -Version 7.0 -RunAsAdministrator
#------------------------------------------------------------------------------
# FILE:         action.ps1
# CONTRIBUTOR:  Jeff Lill
# COPYRIGHT:    Copyright (c) 2005-2021 by neonFORGE LLC.  All rights reserved.
#
# The contents of this repository are for private use by neonFORGE, LLC. and may not be
# divulged or used for any purpose by other organizations or individuals without a
# formal written and signed agreement with neonFORGE, LLC.

# Verify that we're running on a properly configured neonFORGE GitHub runner 
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

Push-Location $ncPowershell | Out-Null
. ./includes.ps1
Pop-Location | Out-Null

# Fetch the inputs

$hostType     = Get-ActionInput      "host-type"      $true
$baseImageUri = Get-ActionInput      "base-image-uri" $true
$buildCommit  = Get-ActionInput      "build-commit"   $true
$buildLogName = Get-ActionInput      "build-log"      $true
$noContainers = Get-ActionInputBool  "no-containers"  $true
$parallelism  = Get-ActionInputInt32 "parallelism"    $true

$buildLogPath = [System.IO.Path]::Combine($env:GITHUB_WORKSPACE, $buildLogName)

# Initialize the outputs

Set-ActionOutput "success"   "true"
Set-ActionOutput "build-log" $buildLogPath

# Perform the operation

try
{
    # We're going to use the [reserved.ip0] address from the neon-assistant
    # profile for the node VM address (if we need to deploy a VM for the operation).

    $vmIP = Get-ProfileValue "reserved.ip0"

    # Validate the target host type and configure the node-image command options

    $targetFolder = $env:GITHUB_WORKSPACE

    if ($noContainers)
    {
        $publishOption = "--no-containers"
    }
    else
    {
        $publishOption = "--publish"
    }

    $hostAddressOption  = ""
    $hostAccountOption  = ""
    $hostPasswordOption = ""
    $nodeAddressOption  = ""
    $nodeNameOption     = ""
    $parallelismOption  = "--parallelism=$parallelism"

    Switch ($hostType)
    {
        "wsl2"
        {
        }

        "hyperv"
        {
            $nodeAddressOption = "--node-address=$vmIP"
        }

        "xenserver"
        {
            $nodeAddressOption = "--node-address=$vmIP"

            # We'll load the target XenServer/XCP-ng host address from the neon-assistant profile.
            #
            # We'll also load the name and vault for the [root] password from the profile and then
            # use that to obtain the actual password for the host.

            $xenHostAddress      = Get-ProfileValue "xen.host.ip"

            $xenCredentialsName  = Get-ProfileValue "xen.credentials.name"
            $xenCredentialsVault = Get-ProfileValue "xen.credentials.vault"
            $xenHostUsername     = Get-SecretValue  "$xenCredentialsName[username]" $xenCredentialsVault
            $xenHostPassword     = Get-SecretValue  "$xenCredentialsName[password]" $xenCredentialsVault
            $xenOwner            = Get-ProfileValue "owner"

            $hostAddressOption   = "--host-address=$xenHostAddress"
            $hostAccountOption   = "--host-account=$xenHostUsername"
            $hostPasswordOption  = "--host-password=$xenHostPassword"

            # Connect to the XenServer host and remove all VMs whose names start with the owner 
            # prefix specified in the profile.  Each runner is expected to have a unique owner
            # assigned to avoid conflicts with other runners.

            Remove-XenServerVMs $xenHostAddress $xenHostUsername $xenHostPassword "$xenOwner-*"
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

    Push-Cwd $ncRoot | Out-Null

        git reset --quiet --hard
        ThrowOnExitCode
    
        git fetch --quiet
        ThrowOnExitCode

        git checkout --quiet --detach $buildCommit
        ThrowOnExitCode

    Pop-Cwd | Out-Null

    #--------------------------------------------------------------------------
    # Build neonCLOUD (including tools) so we can use the [neon-image] tool

    Write-Info ""                                                                                 > $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info "Building neonCLOUD (with tools)"                                                 >> $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info ""                                                                                >> $buildLogPath 2>&1

    $buildScript = [System.IO.Path]::Combine($env:NC_TOOLBIN, "neoncloud-builder.ps1")

    pwsh -File $buildScript -NonInteractive -tools >> $buildLogPath 2>&1
    ThrowOnExitCode

    #--------------------------------------------------------------------------
    # We need to do a partial build of the neonKUBE setup containers so that the
    # [.version] files will be initialized by passing the [-nobuild] option.  This
    # prevents the script from actually building and publishing the containers
    # which is very slow and has already been completed by a previous workflow run.
    #
    # Note that this works because we've checked out neonCLOUD at the same commit
    # where the containers where fully built.

    Write-Info ""                                                                                >> $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info "Initializing setup container images"                                             >> $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info ""                                                                                >> $buildLogPath 2>&1

    $buildScript = [System.IO.Path]::Combine($env:NC_ROOT, "Images", "publish.ps1")

    pwsh -File $buildScript -NonInteractive -setup -nobuild >> $buildLogPath 2>&1
    ThrowOnExitCode

    #--------------------------------------------------------------------------
    # Build and publish the requested node image

    Write-Info ""                                                                                >> $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info "Building [$hostType] node image"                                                 >> $buildLogPath 2>&1
    Write-Info "===============================================================================" >> $buildLogPath 2>&1
    Write-Info ""                                                                                >> $buildLogPath 2>&1

    $neonImagePath = [System.IO.Path]::Combine($env:NC_BUILD, "neon-image", "neon-image.exe")

    # Remove any locally cached node images

    $result = Invoke-CaptureStreams "$neonImagePath prepare clean" -interleave
    Write-Output $result.stdout >> $buildLogPath

    # Prepare the node image for the target environment

    $result = Invoke-CaptureStreams "$neonImagePath prepare node $hostType $targetFolder $baseImageUri $nodeAddressOption $hostAddressOption $hostAccountOption $hostPasswordOption $nodeNameOption $publishOption $parallelismOption" -interleave
}
catch
{
    Write-ActionException $_
    Set-ActionOutput "success" "false"

    # Discard any neonCLOUD commits and checkout master 

    Push-Cwd $ncRoot | Out-Null

        Invoke-CaptureStreams "git reset --quiet --hard" | Out-Null
        Invoke-CaptureStreams "git fetch --quiet" | Out-Null
        Invoke-CaptureStreams "git checkout --quiet master" | Out-Null    
        Invoke-CaptureStreams "git pull --quiet" | Out-Null

    Pop-Cwd | Out-Null
}
