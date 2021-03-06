$currentDir = split-path $SCRIPT:MyInvocation.MyCommand.Path -parent

Import-Module -DisableNameChecking (Join-Path $currentDir './common/utils.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/glazier-profile-tools.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/openstack-tools.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/qemu-img-tools.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/imaging-tools.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/glazier-hostutils.psm1')
Import-Module -DisableNameChecking (Join-Path $currentDir './common/native-swift.psm1')

function New-Image {
  <#
  .SYNOPSIS
      Glazier create-image commandlet
  .DESCRIPTION
      Creates a Windows Server 2012 R2 qcow2 image that is ready to be booted for installation on OpenStack.
  .PARAMETER Name
      A name for the image you want to create
  .PARAMETER GlazierProfilePath
      Path to the glazier profile directory
  .PARAMETER WindowsISOMountPath
      Specifies the location of the Windows iso image
  .PARAMETER VirtIOPath
      Specifies the path to the virtio iso image
  .PARAMETER SizeInMB
      New Image disk size
  .PARAMETER Workspace
      Location for the working directory
  .PARAMETER CleanupWhenDone
      Clean up created files after task is finished. By default this is true
  .PARAMETER ProductKey
      Windows product key
  .PARAMETER Proxy
      Proxy address used inside VM for Windows Updates
  .PARAMETER SkipInitializeStep
      If this flag is set, the image initialization step will be skipped. By default, the Initialize-Image step is automatically run after New-Image completes
  .PARAMETER OpenStackKeyName
      Name of the key
  .PARAMETER OpenStackSecurityGroup
      Comma separated list of security group names
  .PARAMETER OpenStackNetworkId
      UUID of the network
  .PARAMETER OpenStackFlavor
      Name or ID of the flavor
  .PARAMETER Hypervisor
      Specifies the hypervisor to use. Valid options are: 'kvm' (default), 'esxi' or 'kvmforesxi'
  .PARAMETER OpenStackSwiftContainer
      If this is explicitly set to an empty value, upload to swift is bypassed, even if a swift store is detected. By default this is 'glazier-images'
  .NOTES
      Author: Hewlett-Packard Development Company
      Date:   April 8, 2015
  .EXAMPLE
  New-Image -Name "Windows 2012 R2 Core" -GlazierProfilePath "C:\profile"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$Name,
    [Parameter(Mandatory=$true)]
    [string]$GlazierProfilePath,
    [string]$WindowsISOMountPath = '',
    [string]$VirtIOPath='',
    [int]$SizeInMB=25000,
    [string]$Workspace='c:\workspace',
    [switch]$CleanupWhenDone=$true,
    [string]$ProductKey='',
    [string]$Proxy='',
    [switch]$SkipInitializeStep=$false,
    [string]$OpenStackKeyName,
    [string]$OpenStackSecurityGroup,
    [string]$OpenStackNetworkId,
    [string]$OpenStackFlavor,
    [ValidateSet('','kvm','esxi','kvmforesxi')]
    [string]$Hypervisor='',
    [string]$OpenStackSwiftContainer='glazier-images'
  )

  $isVerbose = [bool]$PSBoundParameters["Verbose"]
  $PSDefaultParameterValues = @{"*:Verbose"=$isVerbose}

  if ([string]::IsNullOrWhitespace($WindowsISOMountPath))
  {
    $WindowsISOMountPath = Get-WindowsISOMountPath
  }

  if ([string]::IsNullOrWhitespace($WindowsISOMountPath))
  {
    $WindowsISOMountPath = Read-Host "Windows ISO Mount Path"
  }

  if ([string]::IsNullOrWhitespace($VirtIOPath))
  {
    $VirtIOPath = Get-VirtIOPath
  }

  if ([string]::IsNullOrWhitespace($Hypervisor))
  {
    $Hypervisor = Get-Hypervisor
    if ([string]::IsNullOrWhitespace($Hypervisor))
      {
        throw "Hypervisor is not defined"
      }
  }

  if ([string]::IsNullOrWhitespace($VirtIOPath))
  {
    $VirtIOPath = Read-Host "VirtIO ISO Path"
  }

  if ([string]::IsNullOrWhitespace($ProductKey))
  {
    $ProductKey = Get-ProductKey
  }

  if ([string]::IsNullOrWhitespace($ProductKey))
  {
    $ProductKey = Read-Host "Windows Product Key"
  }

  if ([string]::IsNullOrWhitespace($Proxy))
  {
    $Proxy = Get-WindowsUpdateProxy
  }

  if ([string]::IsNullOrWhitespace($GlazierProfilePath))
  {
    Write-Host -ForegroundColor Red "GlazierProfilePath is empty. Please provide a valid path."
    exit 1
  }
  else
  {
    if ((Test-Path $GlazierProfilePath) -eq $false)
    {
      Write-Verbose "${GlazierProfilePath} not found on the local drive, trying the builder image."
      $GlazierProfilePath = Join-Path 'A:\profiles' $GlazierProfilePath
    }
  }
  if ($SkipInitializeStep -eq $false)
    {
    if ([string]::IsNullOrWhitespace($OpenStackKeyName))
    {
      $OpenStackKeyName = Get-HostArg "os-key-name"
    }

    if ([string]::IsNullOrWhitespace($OpenStackKeyName))
    {
      $OpenStackKeyName = Read-Host "OpenStack SSH Key Name"
    }

    if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
    {
      $OpenStackSecurityGroup = Get-HostArg "os-security-group"
    }

    if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
    {
      $OpenStackSecurityGroup = Read-Host "OpenStack Security Group Name"
    }

    if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
    {
      $OpenStackNetworkId = Get-HostArg "os-network-id"
    }

    if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
    {
      $OpenStackNetworkId = Read-Host "OpenStack Network ID"
    }

    if ([string]::IsNullOrWhitespace($OpenStackFlavor))
    {
      $OpenStackFlavor = Get-HostArg "os-flavor"
    }

    if ([string]::IsNullOrWhitespace($OpenStackFlavor))
    {
      $OpenStackFlavor = Read-Host "OpenStack VM Flavor"
    }
  }

  try
  {
    Write-Output 'Getting profile information ...'
    $glazierProfile = Get-GlazierProfile $GlazierProfilePath
    
    $timestamp = Get-Date -f 'yyyyMMddHHmmss'

    $vhdMountLetter = $null

    # Prepare some variable names
    switch ($Hypervisor)
    {
      "kvm" { $imageExtension = 'qcow2' }
      "kvmforesxi" { $imageExtension = 'qcow2' }
      "esxi" { $imageExtension = 'vmdk' }
    }
    
    $qcow2FileName = "$(Convert-ImageNameToFileName $Name)-$($glazierProfile.Name)-${Hypervisor}-${timestamp}.${imageExtension}"
    Write-Verbose "image filename will be ${qcow2FileName}"
    $vhdFileName = "$(Convert-ImageNameToFileName $Name)-$($glazierProfile.Name)-${Hypervisor}-${timestamp}.vhd"
    Write-Verbose "vhd filename will be ${vhdFileName}"
    $workDir = Join-Path $Workspace $timestamp
    Write-Verbose "Will be working in directory ${workDir}"
    $qcow2Path = Join-Path $Workspace $qcow2FileName
    Write-Verbose "Full image path will be ${qcow2Path}"
    $vhdPath = Join-Path $workDir $vhdFileName
    Write-Verbose "Full vhd path will be ${vhdPath}"
    $wimPath = Join-Path $WindowsISOMountPath 'sources\install.wim'
    Write-Verbose "Will be using wim from ${vhdPath}"
    
    if ($SkipInitializeStep -eq $false)
    {
      Set-OpenStackVars
      Write-Output "Checking OS_* variables ..."
      Validate-OSEnvVars
      Write-Output "Checking nova client can connect to openstack ..."
      Validate-NovaList
      Write-Output "Checking boot image parameters ..."
      Validate-OSParams $OpenStackKeyName $OpenStackSecurityGroup $OpenStackNetworkId $OpenStackFlavor
    }  
   
    if (!(Verify-QemuImg))
    {
        throw "qemu-img not found, aborting."
    }

    if (!(Verify-PythonClientsInstallation))
    {
        throw "Python clients not found, aborting."
    }
    
    if (!(Verify-PythonClientsInstallation))
    {
        throw "Python clients not found, aborting."
    }
    
    if ($SizeInMB -lt 10000)
    {
        throw "Disk size is too small, it needs to be at least 10000 MB."
    }
    
    Write-Output 'Checking to see if script is running with administrative privileges ...'
    Check-IsAdmin

    Write-Output 'Validating wim file ...'
    Validate-WindowsWIM $wimPath

    # Make sure we have a clean working directory
    Write-Output 'Cleaning up work directory ...'
    Clean-Dir $workDir

    Write-Output 'Creating and mounting vhd ...'
    CreateAndMount-VHDImage $vhdPath $SizeInMB ([ref]$vhdMountLetter)

    Write-Output 'Applying wim to vhd ...'
    Apply-Image $wimPath $vhdMountLetter

    Write-Output 'Setting up tools for the unattended install ...'
    Add-UnattendScripts $vhdMountLetter

    Write-Output 'Setting up hypervisor tools for the unattended install ...'
    Add-HypervisorUnattendScripts $vhdMountLetter $Hypervisor

    if([String]::IsNullOrWhiteSpace($Proxy) -eq $false)
    {
        Write-Output 'Generating winupdate_proxy script ...'
        Create-SetProxyScript $vhdMountLetter $Proxy
    }

    Write-Output 'Adding glazier profile to image ...'
    Add-GlazierProfile $vhdMountLetter $glazierProfile

    Write-Output 'Adding glazier resources to image ...'
    Download-GlazierProfileResources $glazierProfile "${vhdMountLetter}:\"

    if ($Hypervisor -eq 'kvm')
    {
      Write-Output 'Adding VirtIO drivers to vhd ...'
      Add-VirtIODriversToImage $vhdMountLetter $VirtIOPath
    }
    
    if ($Hypervisor -eq 'kvmforesxi')
    {
      Write-Output 'Adding VirtIO drivers to vhd ...'
      Add-VirtIODriversToImage $vhdMountLetter $VirtIOPath

      Write-Output 'Adding VMware Tools drivers to vhd ...'
      Add-VMwareToolsDriversToImage $vhdMountLetter $VirtIOPath $workDir
    }
    
    if ($Hypervisor -eq 'esxi')
    {
      Write-Output 'Adding VMware Tools drivers to vhd ...'
      Add-VMwareToolsDriversToImage $vhdMountLetter $VirtIOPath $workDir
    }

    Write-Output 'Making vhd bootable ...'
    Create-BCDBootConfig $vhdMountLetter

    Write-Output 'Configuring Windows features ...'
    Set-DesiredFeatureStateInImage $vhdMountLetter $glazierProfile.FeaturesCSVFile $WindowsISOMountPath

    Write-Output 'Setting up unattend file ...'
    Add-UnattendXml $vhdMountLetter $ProductKey

    Write-Output 'Dismounting vhd ...'
    Dismount-VHDImage $vhdPath

    
    if ($Hypervisor -eq 'kvm')
    {
      Write-Output 'Converting vhd to qcow2 ...'
      Convert-VHDToQCOW2 $vhdPath $qcow2Path
    }
    
    if ($Hypervisor -eq 'kvmforesxi')
    {
      Write-Output 'Converting vhd to qcow2 ...'
      Convert-VHDToQCOW2 $vhdPath $qcow2Path
    }
    
    if ($Hypervisor -eq 'esxi')
    {
      Write-Output 'Converting vhd to vmdk ...'
      Convert-VHDToVMDK $vhdPath $qcow2Path
    }

    Write-Host "Done. Image ready: ${qcow2Path}" -ForegroundColor Green
  }
  catch
  {
    $errorMessage = $_.Exception.Message
    $performConversionToQCOW2 = $false
    Write-Host -ForegroundColor Red "${errorMessage}"

    try
    {
      Write-Output 'Dismounting vhd ...'
      Dismount-VHDImage $vhdPath
    }
    catch
    {
      $errorMessage = $_.Exception.Message
      Write-Warning "Failed to dismount vhd (it must have already happened): ${errorMessage}"
    }

    # If there was an error, we don't want to proceed with the initialize step
    $SkipInitializeStep = $true
  }
  finally
  {
    if ($CleanupWhenDone -eq $true)
    {
      Write-Output 'Cleaning up work directory ...'
      rm -Recurse -Force -Confirm:$false $workDir -ErrorAction SilentlyContinue
    }
  }

  if ($SkipInitializeStep -eq $false)
  {
    Initialize-Image -Qcow2ImagePath $qcow2Path -ImageName $Name -GlazierProfilePath $GlazierProfilePath -OpenStackKeyName $OpenStackKeyName -OpenStackSecurityGroup $OpenStackSecurityGroup -OpenStackNetworkId $OpenStackNetworkId -OpenStackFlavor $OpenStackFlavor -Cleanup:$CleanupWhenDone -Hypervisor $Hypervisor -OpenStackSwiftContainer $OpenStackSwiftContainer
  }
}

function Initialize-Image {
  <#
  .SYNOPSIS
      Glazier Initialize-Image commandlet
  .DESCRIPTION
      If needed, uploads a Windows 2012 R2 qcow2 image created using
      New-Image, then boots it using Nova
  .PARAMETER Qcow2ImagePath
      Path to a qcow2 image created using New-Image
  .PARAMETER ImageName
      Name for the image being created
  .PARAMETER GlazierProfilePath
      Path to the glazier profile directory
  .PARAMETER OpenStackKeyName
      OpenStack key name
  .PARAMETER OpenStackSecurityGroup
      OpenStack security group
  .PARAMETER OpenStackNetworkId
      OpenStack network ID
  .PARAMETER OpenStackFlavor
      OpenStack VM flavor
  .PARAMETER OpenStackSwiftContainer
      If this is explicitly set to an empty value, upload to swift is bypassed, even if a swift store is detected. By default this is 'glazier-images'
  .PARAMETER Cleanup
      Cleanup the workdir after image creation. By default this is true
  .PARAMETER DiskSizeInMB
      Specifies the disk size for the windows image
  .PARAMETER Hypervisor
      Specifies the hypervisor to use. Valid options are: 'kvm' (default), 'esxi' or 'kvmforesxi'
  .NOTES
      Author: Hewlett-Packard Development Company
      Date:   April 8, 2015
  .EXAMPLE
  Initialize-Image -Name "Windows 2012 R2 Core" -Qcow2ImagePath "C:\workspace\image.qcow2"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$Qcow2ImagePath,
    [Parameter(Mandatory=$true)]
    [string]$ImageName,
    [Parameter(Mandatory=$true)]
    [string]$GlazierProfilePath,
    [string]$OpenStackKeyName,
    [string]$OpenStackSecurityGroup,
    [string]$OpenStackNetworkId,
    [string]$OpenStackFlavor,
    [string]$OpenStackSwiftContainer = 'glazier-images',
    [switch]$Cleanup = $true,
    [int]$DiskSizeInMB=25000,
    [ValidateSet('','kvm','esxi','kvmforesxi')]
    [string]$Hypervisor=''
  )

  if ($Cleanup -eq $false)
  {
    Write-Warning "Clean-up flag is set to false. Temporary images and instances will not be deleted."
  }

  $isVerbose = [bool]$PSBoundParameters["Verbose"]
  $PSDefaultParameterValues = @{"*:Verbose"=$isVerbose}

  if ([string]::IsNullOrWhitespace($OpenStackKeyName))
  {
    $OpenStackKeyName = Get-HostArg "os-key-name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackKeyName))
  {
    $OpenStackKeyName = Read-Host "OpenStack SSH Key Name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
  {
    $OpenStackSecurityGroup = Get-HostArg "os-security-group"
  }

  if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
  {
    $OpenStackSecurityGroup = Read-Host "OpenStack Security Group Name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
  {
    $OpenStackNetworkId = Get-HostArg "os-network-id"
  }

  if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
  {
    $OpenStackNetworkId = Read-Host "OpenStack Network ID"
  }

  if ([string]::IsNullOrWhitespace($OpenStackFlavor))
  {
    $OpenStackFlavor = Get-HostArg "os-flavor"
  }

  if ([string]::IsNullOrWhitespace($OpenStackFlavor))
  {
    $OpenStackFlavor = Read-Host "OpenStack VM Flavor"
  }

  if ([string]::IsNullOrWhitespace($GlazierProfilePath))
  {
    Write-Host -ForegroundColor Red "GlazierProfilePath is empty. Please provide a valid path."
    exit 1
  }
  else
  {
    if ((Test-Path $GlazierProfilePath) -eq $false)
    {
      Write-Verbose "${GlazierProfilePath} not found on the local drive, trying the builder image."
      $GlazierProfilePath = Join-Path 'A:\profiles' $GlazierProfilePath
    }
  }

  if ([string]::IsNullOrWhitespace($Hypervisor))
  {
    $Hypervisor = Get-Hypervisor
    if ([string]::IsNullOrWhitespace($Hypervisor))
      {
        throw "Hypervisor is not defined"
      }
  }
  
  try
  {
    Write-Output 'Getting profile information ...'
    $glazierProfile = Get-GlazierProfile $GlazierProfilePath  
    
    $timestamp = Get-Date -f 'yyyyMMddHHmmss'

    $tempVMName = "${ImageName}-$($glazierProfile.Name)-glazier-temp-instance-DO-NOT-USE-${Hypervisor}-${timestamp}"
    Write-Verbose "Temp instance name will be ${tempVMName}"
    $tempImageName = "${ImageName}-$($glazierProfile.Name)-glazier-temp-image-DO-NOT-USE-${Hypervisor}-${timestamp}"
    Write-Verbose "Temp image name will be ${tempImageName}"
    $finalImageName = "${ImageName}-$($glazierProfile.Name)-${Hypervisor}-${timestamp}"
    Write-Verbose "Final image name will be ${finalImageName}"
    
    if ([string]::IsNullOrWhiteSpace($OpenStackSwiftContainer) -eq $false)
    {
      $OpenStackSwiftContainer = "${OpenStackSwiftContainer}-${tempImageName}"
      Write-Verbose "Will be using ${OpenStackSwiftContainer} as a swift container name"
    }
    else
    {
      Write-Warning "The -OpenStackSwiftContainer parameter was explicitly set to an empty value. Swift upload strategy will be skipped."
    }
    
    
    Set-OpenStackVars
  
    Write-Output "Checking OS_* variables ..."
    Validate-OSEnvVars
    Write-Output "Checking boot image parameters ..."
    Validate-OSParams $OpenStackKeyName $OpenStackSecurityGroup $OpenStackNetworkId $OpenStackFlavor

    if (([string]::IsNullOrWhiteSpace($OpenStackSwiftContainer) -eq $false) -and (Validate-SwiftExistence))
    {
      Write-Output "Creating a container on swift ..."
      Create-SwiftContainer $OpenStackSwiftContainer

      Write-Output "Detected an object store, uploading image to swift ..."
      Upload-SwiftNative $Qcow2ImagePath $OpenStackSwiftContainer $tempImageName (1024 * 1024 * 50) 10 $false

      Write-Output "Creating temporary image ..."
      Create-ImageFromSwift $tempImageName $OpenStackSwiftContainer $tempImageName $Hypervisor
    }
    else
    {
      Write-Warning "Did not detect an object store, will try to upload image directly to glance ..."
      Write-Output "Creating temporary image ..."
      Create-Image $tempImageName $Qcow2ImagePath $Hypervisor
    }

	if ($Hypervisor -eq 'esxi')
	{
		Update-ImageProperty $tempImageName 'os_family' 'windows'
		Update-ImageProperty $tempImageName 'vmware_disktype' 'sparse'
		Update-ImageProperty $tempImageName 'vmware_adaptertype' 'paraVirtual'
		Update-ImageProperty $tempImageName 'vmware_ostype' 'windows8Server64Guest'
		Update-ImageProperty $tempImageName 'hypervisor_type' 'vmware'
     }

	Update-ImageProperty $tempImageName 'architecture' 'x86_64'
	Update-ImageProperty $tempImageName 'com.hp__1__os_distro' 'com.microsoft.server'
	Update-ImageProperty $tempImageName 'com.hp__1__bootable_volume' 'true'
	Update-ImageProperty $tempImageName 'com.hp__1__image_type' 'disk'	  
	Update-ImageProperty $tempImageName 'com.hp__1__image_lifecycle' 'active'
	
    Write-Output "Booting temporary instance ..."
    Boot-VM $tempVMName $tempImageName $OpenStackKeyName $OpenStackSecurityGroup $OpenStackNetworkId $OpenStackFlavor $null

    Write-Output "Waiting for temporary instance to finish installation and shut down ..."
    WaitFor-VMShutdown $tempVMName

    Write-Output "Creating final image ..."
    Create-VMSnapshot $tempVMName $finalImageName

    Write-Output "Updating image metadata ..."
	if ($Hypervisor -eq 'esxi')
	{
		Update-ImageProperty $tempImageName 'os_family' 'windows'
		Update-ImageProperty $tempImageName 'vmware_disktype' 'sparse'
		Update-ImageProperty $tempImageName 'vmware_adaptertype' 'paraVirtual'
		Update-ImageProperty $tempImageName 'vmware_ostype' 'windows8Server64Guest'
		Update-ImageProperty $tempImageName 'hypervisor_type' 'vmware'
    }
	
    Update-ImageProperty $finalImageName 'architecture' 'x86_64'
    Update-ImageProperty $finalImageName 'com.hp__1__os_distro' 'com.microsoft.server'
    Update-ImageProperty $finalImageName 'com.hp__1__bootable_volume' 'true'
    Update-ImageProperty $finalImageName 'com.hp__1__image_type' 'disk'
	Update-ImageProperty $tempImageName 'com.hp__1__image_lifecycle' 'active'
 
    Write-Output "Updating image requirements ..."
    $minDiskSize = [int]([Math]::Ceiling(25000 / 1024))
    Update-ImageInfo $finalImageName $mindiskSize 2048
  }
  finally
  {
    try
    {
      if ($Cleanup)
      {
        Write-Output "Deleting temp instance ..."
        Delete-VMInstance $tempVMName
      }
    }
    catch
    {
      $errorMessage = $_.Exception.Message
      Write-Warning "Failed to delete temp instance '${tempVMName}' (it probably doesn't exist): ${errorMessage}"
    }

    try
    {
      if ($Cleanup)
      {
        Write-Output "Deleting temp image ..."
        Delete-Image $tempImageName
      }
    }
    catch
    {
      $errorMessage = $_.Exception.Message
      Write-Warning "Failed to delete temp image '${tempImageName}' (the image probably doesn't exist): ${errorMessage}"
    }

    if (([string]::IsNullOrWhiteSpace($OpenStackSwiftContainer) -eq $false) -and (Validate-SwiftExistence))
    {
      try
      {
        if ($Cleanup)
        {
          Write-Output "Deleting temp image from swift ..."
          Delete-SwiftContainer "${OpenStackSwiftContainer}_segments"
          Delete-SwiftContainer $OpenStackSwiftContainer
        }
      }
      catch
      {
        $errorMessage = $_.Exception.Message
        Write-Warning "Failed to delete temp image '${tempImageName}' from swift (it probably doesn't exist): ${errorMessage}"
      }
    }
  }
}

function Push-Resources {
  <#
  .SYNOPSIS
      Glazier Push-Resources commandlet
  .DESCRIPTION
      Uploads resources for a glazier profile to an existing Windows Server 2012 R2 image that is available on OpenStack glance
  .PARAMETER GlazierProfilePath
      Path to the glazier profile directory
  .PARAMETER VmName
      Name of the VM to boot
  .PARAMETER OpenStackKeyName
      Key name of ssh keypair
  .PARAMETER OpenStackSecurityGroup
      Comma separated list of security group names
  .PARAMETER OpenStackNetworkId
      UUID of the network
  .PARAMETER Image
      Name or ID of the image used to boot the VM
  .PARAMETER SnapshotImageName
      Name of Snapshot to be created
  .PARAMETER OpenStackFlavor
      Name or ID of the flavor
  .PARAMETER HttpProxy
      Http host address proxy used for downloading files
  .PARAMETER HttpsProxy
      Https host address for proxy used for downloading files
  .NOTES
      Author: Hewlett-Packard Development Company
      Date:   April 8, 2015
  .EXAMPLE
  Push-Resources -GlazierProfilePath c:\myprofile -VmName Win2012 -KeyName private-ssh-key -SecurityGroup security-group -NetworkId uuid -Image uuid -SnapshotImageName win-snapshot -Flavor standard.medium
  #>
[CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$GlazierProfilePath,
    [string]$OpenStackKeyName = '',
    [string]$OpenStackSecurityGroup = '',
    [string]$OpenStackNetworkId = '',
    [Parameter(Mandatory=$true)]
    [string]$Image,
    [Parameter(Mandatory=$true)]
    [string]$SnapshotImageName,
    [string]$OpenStackFlavor = '',
    [string]$HttpProxy=$null,
    [string]$HttpsProxy=$null
  )

  $isVerbose = [bool]$PSBoundParameters["Verbose"]
  $PSDefaultParameterValues = @{"*:Verbose"=$isVerbose}

  if ([string]::IsNullOrWhitespace($GlazierProfilePath))
  {
    Write-Host -ForegroundColor Red "GlazierProfilePath is empty. Please provide a valid path."
    exit 1
  }
  else
  {
    if ((Test-Path $GlazierProfilePath) -eq $false)
    {
      Write-Verbose "${GlazierProfilePath} not found on the local drive, trying the builder image."
      $GlazierProfilePath = Join-Path 'A:\profiles' $GlazierProfilePath
    }
  }

  Set-OpenStackVars

  if ([string]::IsNullOrWhitespace($OpenStackKeyName))
  {
    $OpenStackKeyName = Get-HostArg "os-key-name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackKeyName))
  {
    $OpenStackKeyName = Read-Host "OpenStack Key Name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
  {
    $OpenStackSecurityGroup = Get-HostArg "os-security-group"
  }

  if ([string]::IsNullOrWhitespace($OpenStackSecurityGroup))
  {
    $OpenStackSecurityGroup = Read-Host "OpenStack Security Group Name"
  }

  if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
  {
    $OpenStackNetworkId = Get-HostArg "os-network-id"
  }

  if ([string]::IsNullOrWhitespace($OpenStackNetworkId))
  {
    $OpenStackNetworkId = Read-Host "OpenStack Network ID"
  }

  if ([string]::IsNullOrWhitespace($OpenStackFlavor))
  {
    $OpenStackFlavor = Get-HostArg "os-flavor"
  }

  if ([string]::IsNullOrWhitespace($OpenStackFlavor))
  {
    $OpenStackFlavor = Read-Host "OpenStack VM Flavor"
  }

  try
  {
    $glazierProfile = Get-GlazierProfile $GlazierProfilePath

    $timestamp = Get-Date -f 'yyyyMMddHHmmss'

    $VmName = "${Image}-$($glazierProfile.Name)-glazier-temp-instance-DO-NOT-USE-${timestamp}"
    Write-Verbose "Temp instance name will be ${VmName}"
    $SnapshotImageName = "${SnapshotImageName}-$($glazierProfile.Name)-${timestamp}"
    Write-Verbose "Final image name will be ${SnapshotImageName}"

    Validate-OSEnvVars
 
    Write-Verbose "Generating user-data script"
    $stringBuilder = New-Object System.Text.StringBuilder
    $stringBuilder.AppendLine("#ps1")
    $stringBuilder.AppendLine(@'
function Download-File{[CmdletBinding()]param($url, $targetFile, $proxy)
  Write-Verbose "Downloading '${url}' to '${targetFile}'"
  $uri = New-Object "System.Uri" "$url"
  $request = [System.Net.HttpWebRequest]::Create($uri)
  if($proxy -ne $null)
  {
    $request.Proxy = $proxy
  }
  $request.set_Timeout(15000) #15 second timeout
  $response = $request.GetResponse()
  $totalLength = [System.Math]::Floor($response.get_ContentLength()/1024)
  $responseStream = $response.GetResponseStream()
  $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $targetFile, Create
  $buffer = new-object byte[] 10KB
  $count = $responseStream.Read($buffer,0,$buffer.length)
  $downloadedBytes = $count
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  while ($count -gt 0)
  {
     $targetStream.Write($buffer, 0, $count)
     $count = $responseStream.Read($buffer,0,$buffer.length)
     $downloadedBytes = $downloadedBytes + $count

     if ($sw.Elapsed.TotalMilliseconds -ge 500) {
       $activity = "Downloading file '$($url.split('/') | Select -Last 1)'"
       $status = "Downloaded ($([System.Math]::Floor($downloadedBytes/1024))K of $($totalLength)K): "
       $percentComplete = ((([System.Math]::Floor($downloadedBytes/1024)) / $totalLength)  * 100)
       Write-Progress -activity $activity -status $status -PercentComplete $percentComplete

       $sw.Reset();
       $sw.Start()
    }
  }

  Write-Progress -activity "Finished downloading file '$($url.split('/') | Select -Last 1)'" -Completed -status "Done"
  $targetStream.Flush()
  $targetStream.Close()
  $targetStream.Dispose()
  $responseStream.Dispose()
}
'@)

    $stringBuilder.AppendLine("`$destDir = `$env:SystemDrive")
    $csv = Import-Csv $glazierProfile.ResourcesCSVFile
    $userData = [System.IO.Path]::GetTempFileName()
    if(![string]::IsNullOrEmpty($HttpProxy))
    {
      $stringBuilder.AppendLine("`$proxy = new-object System.Net.WebProxy -ArgumentList `"${HttpProxy}`"")
    }
    elseif (![string]::IsNullOrEmpty($HttpsProxy))
    {
      $stringBuilder.AppendLine("`$proxy = new-object System.Net.WebProxy -ArgumentList `"${HttpsProxy}`", 433")
    }
    else
    {
      $stringBuilder.AppendLine("`$proxy = `$null")
    }

    Foreach ($line in $csv)
    {
      $localFileName = [System.IO.Path]::GetFileNameWithoutExtension(($line.path -replace '[-_]',''))
      $stringBuilder.AppendLine("`$${localFileName}Path = Join-Path `$destDir `"$($line.path)`"")
      $stringBuilder.AppendLine("New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName(`$${localFileName}Path))")
      $stringBuilder.AppendLine("Download-File -url `"$($line.uri)`" -targetFile `$${localFileName}Path -proxy `$proxy")
    }

    $stringBuilder.AppendLine("shutdown /s /t 100")
    $stringBuilder.ToString() | Out-File $userData -Encoding ascii

    Boot-VM $VmName $Image $OpenStackKeyName $OpenStackSecurityGroup $OpenStackNetworkId $OpenStackFlavor $userData

    WaitFor-VMShutdown $VmName

    Write-Verbose "Creating VM Snapshot ${SnapshotImageName}"
    Create-VMSnapshot $VmName $SnapshotImageName

    Write-Output "Updating image metadata ..."
    Update-ImageProperty $SnapshotImageName 'architecture' 'i686'
    Update-ImageProperty $SnapshotImageName 'com.hp__1__os_distro' 'com.microsoft.server'
  }
  finally{
    If (Test-Path $userData){
	  Remove-Item $userData
    }
  }
}

Export-ModuleMember -Function 'Initialize-Image', 'Push-Resources', 'New-Image'
