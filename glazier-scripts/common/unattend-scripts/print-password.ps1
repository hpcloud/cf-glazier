
$maxAttempts = 15
$encryptedPassword = ''

for($i=1; $i -le $maxAttempts; $i++)
{
  $encryptedPassword = (wget http://169.254.169.254/openstack/2013-04-04/password -UseBasicParsing).Content

  if ([string]::IsNullOrWhitespace($encryptedPassword) -eq $false)
  {
    Write-Output '-----BEGIN BASE64-ENCODED ENCRYPTED PASSWORD-----'
    Write-Output $encryptedPassword
    Write-Output '-----END BASE64-ENCODED ENCRYPTED PASSWORD-----'
    return
  }

  Start-Sleep -Seconds 10
}
