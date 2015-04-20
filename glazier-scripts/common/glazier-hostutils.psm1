
function Check-ArgsList{[CmdletBinding()]param()
  # gets the values from A:\args.csv
  $argslist = Import-csv A:\args.csv -Header @("name","value")

  # echo them out
  foreach ($line in $argslist)
  {
    echo "$($line.name) $($line.value)"
  }
}

function Set-OpenStackVars()
{
  # load openrc info
  $envVars = Import-csv A:\env.csv -Header @("name","value")

  # put them into the environment
  foreach ($line in $envVars)
  {
    $varName = $line.name
    $varValue = $line.value
    Write-Verbose "Setting var ${varName} ..."
    New-Item env:\$varName -Value $varValue
  }

  Check-CACERT
}

function Check-CACERT{[CmdletBinding()]param()
  # if A:\cacert exists, put it in env
  $FileExist = Test-Path A:\cacert

  if ( $FileExist -eq $True )
  {
    $env:OS_CACERT = "A:\cacert"
  }
}

function Get-VirtIOPath{[CmdletBinding()]param()
  $fileExist = Test-Path A:\driveletters.csv

  if ($fileExist -eq $True)
  {
    $driveLetter = Import-csv A:\driveletters.csv -Header @("drive","type") | Where-Object {$_.type -eq "virtio"}
    return $driveLetter.drive
  }
  else
  {
    return ''
  }
}

function Get-WindowsISOMountPath{[CmdletBinding()]param()
  $fileExist = Test-Path A:\driveletters.csv

  if ($fileExist -eq $True)
  {
    $driveLetter = Import-csv A:\driveletters.csv -Header @("drive","type") | Where-Object {$_.type -eq "windows"}
    return $driveLetter.drive
  }
  else
  {
    return ''
  }
}

function Get-ProductKey{[CmdletBinding()]param()
  $fileExist = Test-Path A:\args.csv

  if ($fileExist -eq $True)
  {
    $arg = Import-csv A:\args.csv -Header @("name","value") | Where-Object {$_.type -eq "product-key"}
    return $arg.value
  }
  else
  {
    return ''
  }
}
