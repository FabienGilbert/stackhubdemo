############################################################################################
# Kick-off ARM template deployment for ADDS and ADFS Identity solution on Azure Stack Hub  #
# Created: 2021-04                                                                         #
# Last update: 2021-04                                                                     #
# Author: Fabien Gilbert, Microsoft                                                        #
############################################################################################

$templateFileName = "azuredeploy.json"
$parameterFileName = "azuredeploy.parameters.stack.json"

# Function to generate random password
function Get-RandomPassword {
    param (
        #Password length
        [Parameter(Mandatory = $true, 
            Position = 0)]
        [ValidateRange(8, 64)] 
        [Int]
        $Length
    )    
    $SegmentTypes = "[
        {
            'Number': 1,
            'MinimumRandom': 65,
            'MaximumRandom': 91
        },
        {
            'Number': 2,
            'MinimumRandom': 97,
            'MaximumRandom': 122
        },
        {
            'Number': 3,
            'MinimumRandom': 48,
            'MaximumRandom': 58
        },
        {
            'Number': 4,
            'MinimumRandom': 37,
            'MaximumRandom': 47
        }
    ]" | ConvertFrom-Json
    $PasswordSegments = @()
    do {
        $Fourtet = @()    
        do {
            $SegmentsToAdd = @()
            foreach ($SegmentType in $SegmentTypes) {
                if ($Fourtet -notcontains $SegmentType.Number) { $SegmentsToAdd += $SegmentType.Number }
            }
            $RandomSegment = Get-Random -InputObject $SegmentsToAdd
            $Fourtet += $RandomSegment
            $PasswordSegments += $RandomSegment
        }until($Fourtet.Count -ge 4 -or $PasswordSegments.Count -ge $Length)    
    }until($PasswordSegments.Count -ge $Length)
    $RandomPassword = $null
    foreach ($PasswordSegment in $PasswordSegments) {
        $SegmentType = $null; $SegmentType = $SegmentTypes | Where-Object -Property Number -EQ -Value $PasswordSegment    
        $RandomPassword += [char](Get-Random -Minimum $SegmentType.MinimumRandom -Maximum $SegmentType.MaximumRandom)
    }
    ConvertTo-SecureString -AsPlainText -Force -String $RandomPassword
}
# Function to get a VM local user password, out of key vault if existing or a random one
function Get-VmPassword {
    param (
        #DeploymentPrefix
        [Parameter(Mandatory = $true, 
            Position = 0)]
        [ValidateNotNullOrEmpty()] 
        [String]
        $DeploymentPrefix,
        
        #Username
        [Parameter(Mandatory = $true, 
            Position = 1)]
        [ValidateNotNullOrEmpty()]
        [String]
        $Username
    )    
    
    $keyVaultName = ($DeploymentPrefix + "-CORE-AKV")
    $keyVaultSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $Username -ErrorAction:SilentlyContinue
    $secretHash = @{"deploy" = $false; "secret" = "" }
    if ($keyVaultSecret) {
        Write-Host ("`tfound existing password for username " + [char]34 + $Username + [char]34 + " in Key Vault " + [char]34 + $keyVaultName + ".")
        $secretHash.secret = $keyVaultSecret.SecretValue
    }
    else {
        Write-Host ("`tgenerating random password username " + [char]34 + $Username + [char]34 + "...")
        $randomPwd = Get-RandomPassword -Length 12
        $secureRandomPwd = ConvertTo-SecureString -AsPlainText -Force -String $randomPwd
        $secretHash.secret = $secureRandomPwd
        $secretHash.deploy = $true
    }
    $secretHash
}
# Function to get/create storage account for automation files and return context
function Get-AutomationStorageAccount {
    param (
        [Parameter(Position = 0,
            HelpMessage = "Storage account name",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [string]
        $StorageAccountName,

        [Parameter(Position = 1,
            HelpMessage = "Storage account resource group",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [string]
        $StorageAccountResourceGroup,

        [Parameter(Position = 2,
            HelpMessage = "Storage account location",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [string]
        $StorageAccountLocation
    )    
    
    # Get existing storage account
    Write-Host ("`r`nGetting storage account name " + [char]34 + $StorageAccountName + [char]34 + " resource group " + [char]34 + $StorageAccountResourceGroup + [char]34 + "...")
    $store = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName -ErrorAction:SilentlyContinue    
    if ($store) {
        Write-Host "`tstorage account already exists"
    }
    else {
        Write-Host "`tcreating storage account..." 
        $store = New-AzStorageAccount -ResourceGroupName $resourceGroupName -AccountName $storageAccountName -SkuName Standard_LRS -Kind Storage -Location $StorageAccountLocation
        if ($store.ProvisioningState -eq "succeeded") { "`tstorage account created successfully." }
        else { Write-Error -Message ("Could not create Storage Account " + [char]34 + $StorageAccountName + [char]34 + "."); exit }
    }
    # Return storage account object
    $store
}
# Function to get/create storage account container for automation files
function Get-AutomationContainer {
    param (
        [Parameter(Position = 0,
            HelpMessage = "Storage account context",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [object]
        $StorageAccountContext,

        [Parameter(Position = 1,
            HelpMessage = "Container name",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [string]
        $ContainerName,

        [Parameter(Position = 2,
            HelpMessage = "Container permission")]
        [ValidateSet("Off", "Container", "Blob")] 
        [string]
        $ContainerPermission = "Off"
    )    
    
    # Get existing storage account container
    Write-Host ("`r`nGetting storage account container " + [char]34 + $ContainerName + [char]34 + "...")
    $cont = Get-AzStorageContainer -Context $StorageAccountContext -Name $ContainerName -ErrorAction:SilentlyContinue
    if ($cont) { Write-Host "`tfound existing container." }
    else {
        Write-Host "`tcreating container..."
        $cont = New-AzStorageContainer -Context $StorageAccountContext -Name $ContainerName -Permission $ContainerPermission
    }
    # Return container object
    if ($cont) { $cont }
    else {
        Write-Error -Message ("`r`nCould not create storage account container " + [char]34 + $ContainerName + [char]34 + ".")
    }
}
# Function to upload automation files to storage account
function Set-AutomationBlob {
    param (
        [Parameter(Position = 0,
            HelpMessage = "Storage account context",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [object]
        $StorageAccountContext,

        [Parameter(Position = 1,
            HelpMessage = "Container name",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [string]
        $ContainerName,

        [Parameter(Position = 2,
            HelpMessage = "Local files",
            Mandatory = $true)]
        [ValidateNotNullOrEmpty()]  
        [array]
        $LocalFiles,

        [Parameter(Position = 3,
            HelpMessage = "Local folder",
            Mandatory = $true)]    
        [ValidateNotNullOrEmpty()]  
        [string]
        $LocalFolder,

        [Parameter(Position = 4,
            HelpMessage = "Current folder")]    
        [ValidateNotNullOrEmpty()]  
        [string]
        $CurrentFolder = (Split-Path $script:MyInvocation.MyCommand.Path)
    )    
    
    # Check local folder path
    $LocalFolderPath = Join-Path -Path $CurrentFolder -ChildPath $LocalFolder
    Write-Host ("Looking for local folder " + [char]34 + $LocalFolderPath + [char]34 + "...")
    if(Test-Path -Path $LocalFolderPath){Write-Host ("`tfound it.")}
    else{Write-Error -Message ("Could not find folder " + [char]34 + $LocalFolderPath + [char]34 + ".");exit}

    # Loop through local files
    foreach($LocalFile in $LocalFiles){
        # Get local file
        $LocalFilePath = Join-Path -Path $LocalFolderPath -ChildPath $LocalFile
        Write-Host ("Getting local file " + [char]34 + $LocalFilePath + [char]34 + "...")
        $file = Get-ChildItem -Path $LocalFilePath
        if($file){Write-Host ("`tfound file length " + $file.Length + " last write time " + $file.LastWriteTime + ".")}
        else{Write-Error -Message ("Could not get local file " + [char]34 + $LocalFilePath + [char]34 + ".");exit}
        # Get blob if existing
        $blob = Get-AzStorageBlob -Context $StorageAccountContext -Container $ContainerName -Blob $LocalFile -ErrorAction:SilentlyContinue
        $upload = $true
        if($blob){
            Write-Host ("`tfound blob length " + $blob.Length + " last modified " + $blob.LastModified + ".")
            if($file.Length -eq $blob.Length -and $file.LastWriteTime -le $blob.LastModified.LocalDateTime){$upload = $false}            
        }
        else{Write-Host "`tno existing blob could be found."}
        # Upload blob
        if($upload){
            Write-Host ("`tuploading file to container...")
            $blobUpload = Set-AzStorageBlobContent -Context $StorageAccountContext -Container $ContainerName -Blob $LocalFile -File $LocalFilePath
            $blob = Get-AzStorageBlob -Context $StorageAccountContext -Container $ContainerName -Blob $LocalFile -ErrorAction:SilentlyContinue
            if($blob){Write-Host "`tfound blob."}
            else{Write-Error -Message ("Could not upload blob " + [char]34 + $LocalFile + [char]34 + " to container " + [char]34 + $ContainerName + [char]34 + ".");exit}
        }
        else{Write-Output "`tkeeping existing blob."}
    }    
}

# Import parameter file
$currentFolder = Split-Path $script:MyInvocation.MyCommand.Path
$parameterFilePath = Join-Path -Path $currentFolder -ChildPath $parameterFileName
$parameterFile = Get-Content -Path $parameterFilePath | ConvertFrom-Json
if (!($parameterFile)) { Write-Error -Message ("Could not import JSON Parameter file " + [char]34 + $parameterFilePath + [char]34 + "."); exit }

# Create Resource Group
$resourceGroupName = ($parameterFile.parameters.deploymentPrefix.value + "-CORESVC-RGP")
Write-Output ("`r`nChecking existence of Resource Group " + [char]34 + $resourceGroupName + [char]34 + "...")
$rgp = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction:SilentlyContinue
if ($rgp) {
    Write-Output "`tresource group already exists"
}
else {
    Write-Output "`tcreating resource group..."   
    $rgp = New-AzResourceGroup -Name $resourceGroupName -Tag @{"system" = $parameterFile.parameters.tagSystem.value } -Location $parameterFile.parameters.deploymentLocation.value
    if ($rgp.ProvisioningState -eq "succeeded") { "`tresource group created successfully." }
    else { Write-Error -Message ("Could not create Resource Group " + [char]34 + $resourceGroupName + [char]34 + "."); exit }
}

# Create automation storage account
$storageAccountName = ($parameterFile.parameters.deploymentPrefix.value + "coreautostore").ToLower()
$autoStore = Get-AutomationStorageAccount -StorageAccountName $storageAccountName -StorageAccountResourceGroup $resourceGroupName -StorageAccountLocation $parameterFile.parameters.deploymentLocation.value
# Create DSC container
$dscContainer = Get-AutomationContainer -StorageAccountContext $autoStore.Context -ContainerName "dsc" -ContainerPermission "Blob"
# Upload DSC files
Set-AutomationBlob -StorageAccountContext $autoStore.Context -ContainerName $dscContainer.Name -LocalFolder "extensions\dsc" -LocalFiles @(
                                                                                                                                              ($parameterFile.parameters.adds01dscConfig.value + ".ps1.zip"),
                                                                                                                                              ($parameterFile.parameters.adds02dscConfig.value + ".ps1.zip"),
                                                                                                                                              ($parameterFile.parameters.adfsDscConfig.value + ".ps1.zip"),
                                                                                                                                              ($parameterFile.parameters.adcaDscConfig.value + ".ps1.zip"),
                                                                                                                                              ($parameterFile.parameters.wapDscConfig.value + ".ps1.zip"),
                                                                                                                                              ($parameterFile.parameters.jumpDscConfig.value + ".ps1.zip")
                                                                                                                                          )

# Get local user passwords from Key Vault Secrets if existing, or generate them
Write-Output "`r`nGetting local username passwords from Key Vault, if existing, or generate them..."
$daUser = Get-VmPassword -DeploymentPrefix $parameterFile.parameters.deploymentPrefix.value -Username $parameterFile.parameters.daUserName.value
$laUser = Get-VmPassword -DeploymentPrefix $parameterFile.parameters.deploymentPrefix.value -Username $parameterFile.parameters.laUserName.value
$djUser = Get-VmPassword -DeploymentPrefix $parameterFile.parameters.deploymentPrefix.value -Username $parameterFile.parameters.djUserName.value

# Kick-off ARM template deployment
Write-Output ("`r`nDeploying ARM Template " + [char]34 + $templateFileName + [char]34 + " with parameter file " + [char]34 + $parameterFileName + [char]34 + " to Resource Group " + [char]34 + $resourceGroupName + [char]34 + "...")
$templateFilePath = Join-Path -Path $currentFolder -ChildPath $templateFileName
$deploymentName = ("CORESVC_" + (Get-Date -UFormat %Y%m%d%H%M%S))
$armDeployment = New-AzResourceGroupDeployment -Name $deploymentName `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile $templateFilePath `
    -TemplateParameterFile $parameterFilePath `
    -daUserPassword $daUser.secret `
    -deployDaUser $daUser.deploy `
    -laUserPassword $laUser.secret `
    -deployLaUser $laUser.deploy `
    -djUserPassword $djUser.secret `
    -deployDjUser $djUser.deploy `
    -rootDscUri $dscContainer.CloudBlobContainer.Uri.AbsoluteUri `
    -Verbose
Write-Output ("`r`nARM Template deployment completed with status: " + $armDeployment.ProvisioningState)