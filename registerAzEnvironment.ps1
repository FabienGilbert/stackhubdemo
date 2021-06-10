# Install right version of package management
Install-Module PowerShellGet -MinimumVersion 2.2.3 -Force

# Install AZ Modules supported by Azure Stack Hub
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module -Name Az.BootStrapper -Force -AllowPrerelease
Install-AzProfile -Profile 2019-03-01-hybrid -Force
Install-Module -Name AzureStack -RequiredVersion 2.0.2-preview -AllowPrerelease

# Register Stack Hub management endpoint
Add-AzEnvironment -Name "AzureStack" -ARMEndpoint "https://management.contoso.com"

# Connect to Azure PowerShell
Connect-AzAccount -Environment "AzureStack"