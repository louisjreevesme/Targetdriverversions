[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
$mydownloads = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path

$MyTemp =(Get-Item $mydownloads).fullname
 set-location -Path $mytemp
 
$myloca = "$mytemp\"
 
 try
 {

$response = Invoke-WebRequest -Uri https://github.com/Louisjreevesme/targetdriverversions/raw/main/targetdrivrversions.zip -OutFile $MyTemp\targetdriverversions.zip  
 } catch 
 {
    $StatusCode = $_.Exception.Response.StatusCode.value__
  }
  

      Expand-Archive -Path $mydownloads\targetdriverversions.zip -DestinationPath $mydownloads\targetdriverversions\ -Force
 
 
 
 
 set-location "$mydownloads\targetdriverversions\" 
  .\targetdriverversions.ps1
