$currentDir = split-path $SCRIPT:MyInvocation.MyCommand.Path -parent
Import-Module -DisableNameChecking (Join-Path $currentDir './utils.psm1')

$qemuDir = Join-Path $env:SYSTEMDRIVE 'qemu'
$qemuBin = Join-Path $qemuDir 'qemu-img.exe'

function Verify-QemuImg{[CmdletBinding()]param()
  return (Test-Path $qemuBin)
}

function Install-QemuImg{[CmdletBinding()]param()
  Write-Verbose "Installing qemu-img ..."
  $qemuUrl = Get-Dependency 'qemu-img'
  Clean-Dir $qemuDir

  $qemuZip = Join-Path $qemuDir 'qemu.zip'
  Write-Verbose "Downloading qemu ..."
  Download-File-With-Retry $qemuUrl $qemuZip

  Write-Verbose "Extracting qemu ..."
  $fileSystemAssemblyPath = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'System.IO.Compression.FileSystem.dll'
  Add-Type -Path $fileSystemAssemblyPath
  [System.IO.Compression.ZipFile]::ExtractToDirectory($qemuZip, $qemuDir)

  Write-Verbose "Copying qemu files ..."
  $qemuExpandedPath = (dir (Join-Path $qemuDir 'qemu-windows-*')).FullName
  Copy-Item -Recurse (Join-Path $qemuExpandedPath '\*') $qemuDir

  Write-Verbose "Cleaning up qemu install dir ..."
  rm -Recurse -Force -Confirm:$false $qemuExpandedPath -ErrorAction SilentlyContinue
  rm -Force -Confirm:$false $qemuZip -ErrorAction SilentlyContinue
}

function Convert-VHDToQCOW2{[CmdletBinding()]param($sourceVhd, $destinationQcow2)
  Write-Verbose "Converting vhd '${sourceVhd}' to qcow2 '${destinationQcow2}' ..."

  $convertProcess = Start-Process -Wait -PassThru -NoNewWindow $qemuBin "convert -o compat=0.10 -O qcow2 `"${sourceVhd}`" `"${destinationQcow2}`""

  if ($convertProcess.ExitCode -ne 0)
  {
    throw 'Converting vhd to qcow2 failed.'
  }
  else
  {
    Write-Verbose "vhd converted to qcow2 successfully."
  }
}

function Convert-VHDToVMDK{[CmdletBinding()]param($sourceVhd, $destinationVmdk)
  Write-Verbose "Converting vhd '${sourceVhd}' to vmdk '${destinationVmdk}' ..."

  $convertProcess = Start-Process -Wait -PassThru -NoNewWindow $qemuBin "convert -o adapter_type=lsilogic -O vmdk `"${sourceVhd}`" `"${destinationVmdk}`""

  if ($convertProcess.ExitCode -ne 0)
  {
    throw 'Converting vhd to vmdk failed.'
  }
  else
  {
    Write-Verbose "vhd converted to vmdk successfully."
  }
}

