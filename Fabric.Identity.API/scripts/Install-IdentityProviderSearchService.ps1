﻿param(
    [PSCredential] $credential, 
    [Hashtable] $configStore = @{Type = "File"; Format = "XML"; Path = "$PSScriptRoot\install.config"},
    [Hashtable] $azureConfigStore = @{Type = "File"; Format = "XML"; Path = "$env:ProgramFiles\Health Catalyst\azuresettings.config"},
    [switch] $noDiscoveryService, 
    [switch] $quiet
)
if (!(Test-Path $configStore.Path)) {
    throw "Path $($configStore.Path) does not exist. Please enter valid path to the install.config."
}
if (!(Test-Path $configStore.Path -PathType Leaf)) {
    throw "Path $($configStore.Path) is not a file. Please enter a valid path to the install.config."
}
Import-Module -Name .\Install-Identity-Utilities.psm1 -Force

# Import Fabric Install Utilities
$fabricInstallUtilities = ".\Fabric-Install-Utilities.psm1"
if (!(Test-Path $fabricInstallUtilities -PathType Leaf)) {
    Write-DosMessage -Level "Warning" -Message "Could not find fabric install utilities. Manually downloading and installing"
    Get-WebRequestDownload -Uri https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/common/Fabric-Install-Utilities.psm1 -NoCache -OutFile $fabricInstallUtilities
}
Import-Module -Name $fabricInstallUtilities -Force

# Especially calling this script from another script, this message is helpful
Write-DosMessage -Level "Information" -Message "Starting IdentityProviderSearchService installation..."

$identitySettingsScope = "identity"
$identityConfigStore = Get-DosConfigValues -ConfigStore $configStore -Scope $identitySettingsScope
# Check for useAzure setting
$useAzure = $identityConfigStore.useAzureAD
if($null -eq $useAzure) {
    $useAzure = $false
    Add-InstallationSetting -configSection $identitySettingsScope -configSetting "useAzureAD" -configValue "$useAzure" -installConfigPath $configStore.Path  | Out-Null
}

# Verify azure settings file exists if azure is enabled
if($useAzure -eq $true) {
    if (!(Test-Path $azureConfigStore.Path)) {
        throw "Path $($azureConfigStore.Path) does not exist and is required when useAzure is set to true. Please enter valid path to the azuresettings.config."
    }
    if (!(Test-Path $azureConfigStore.Path -PathType Leaf)) {
        throw "Path $($azureConfigStore.Path) is not a file and is required when useAzure is set to true. Please enter a valid path to the azuresettings.config."
    }
}

# Get Idpss app pool user 
# Create log directory with read/write permissions for app pool user
# using methods in DosInstallUtilites to install idpss, which will make it easier to migrate the identity code later 
$idpssSettingsScope = "identityProviderSearchService"
$idpssConfigStore = Get-DosConfigValues -ConfigStore $configStore -Scope $idpssSettingsScope
$commonConfigStore = Get-DosConfigValues -ConfigStore $configStore -Scope "common"
$idpssInstallSettings = Get-InstallationSettings $idpssSettingsScope -installConfigPath $configStore.Path
Set-LoggingConfiguration -commonConfig $commonConfigStore

$certificates = Get-Certificates -primarySigningCertificateThumbprint $identityConfigStore.primarySigningCertificateThumbprint `
            -encryptionCertificateThumbprint $identityConfigStore.encryptionCertificateThumbprint `
            -installConfigPath $configStore.Path `
            -scope $identitySettingsScope `
            -quiet $quiet

$idpssIisUser = Get-IISAppPoolUser -credential $credential -appName $idpssConfigStore.appName -storedIisUser $idpssConfigStore.iisUser -installConfigPath $configStore.Path -scope $idpssSettingsScope

Add-PermissionToPrivateKey $idpssIisUser.UserName $certificates.SigningCertificate read
$appInsightsKey = Get-AppInsightsKey -appInsightsInstrumentationKey $identityConfigStore.appInsightsInstrumentationKey -installConfigPath $configStore.Path -scope $identitySettingsScope -quiet $quiet
$sqlServerAddress = Get-SqlServerAddress -sqlServerAddress $commonConfigStore.sqlServerAddress -installConfigPath $configStore.Path -quiet $quiet
$metadataDatabase = Get-MetadataDatabaseConnectionString -metadataDbName $commonConfigStore.metadataDbName -sqlServerAddress $sqlServerAddress -installConfigPath $configStore.Path -quiet $quiet

if(!$noDiscoveryService){
    $discoveryServiceUrl = Get-DiscoveryServiceUrl -discoveryServiceUrl $commonConfigStore.discoveryService -installConfigPath $configStore.Path -quiet $quiet
}

$idpssServiceUrl = Get-ApplicationEndpoint -appName $idpssConfigStore.appName `
    -applicationEndpoint $idpssConfigStore.applicationEndPoint `
    -installConfigPath $configStore.Path `
    -scope $idpssSettingsScope `
    -quiet $quiet `
    -addInstallSetting $false

$currentUserDomain = Get-CurrentUserDomain -quiet $quiet

$idpssStandalonePath = "$PSScriptRoot\Fabric.IdentityProviderSearchService.zip"
$idpssInstallerPath = "$PSScriptRoot\..\WebDeployPackages\Fabric.IdentityProviderSearchService.zip"
$idpssInstallPackagePath = Get-WebDeployPackagePath -standalonePath $idpssStandalonePath -installerPath $idpssInstallerPath
$selectedSite = Get-IISWebSiteForInstall -selectedSiteName $idpssInstallSettings.siteName -quiet $quiet -installConfigPath $configStore.Path -scope $idpssSettingsScope

$secretNoEnc = $commonConfigStore.fabricInstallerSecret -replace "!!enc!!:"

$decryptedSecret = Unprotect-DosInstallerSecret -CertificateThumprint $commonConfigStore.encryptionCertificateThumbprint -EncryptedInstallerSecretValue $secretNoEnc

$registrationApiSecret = Add-IdpssApiResourceRegistration -identityServiceUrl $commonConfigStore.identityService -fabricInstallerSecret $decryptedSecret

$idpssWebDeployParameters = Get-IdpssWebDeployParameters -serviceConfig $idpssConfigStore `
                        -commonConfig $commonConfigStore `
                        -applicationEndpoint $idpssServiceUrl `
                        -discoveryServiceUrl $discoveryServiceUrl `
                        -noDiscoveryService $noDiscoveryService `
                        -registrationApiSecret $registrationApiSecret `
                        -metadataConnectionString $metadataDatabase.DbConnectionString `
                        -currentDomain $currentUserDomain

Write-DosMessage -Level Information -Message "Enter credentials for app pool $($idpssConfigStore.appPoolName)"
$idpssInstallApplication = Publish-DosWebApplication -WebAppPackagePath $idpssInstallPackagePath `
                      -WebDeployParameters $idpssWebDeployParameters `
                      -AppPoolName $idpssConfigStore.appPoolName `
                      -AppName $idpssConfigStore.appName `
                      -AppPoolCredential $idpssIisUser.Credential `
                      -AuthenticationType "Anonymous" `
                      -WebDeploy

$idpssDirectory = [io.path]::combine([System.Environment]::ExpandEnvironmentVariables($selectedSite.physicalPath), $idpssConfigStore.appName)
Write-Host "IdPSS Directory: $($idpssDirectory)"
New-LogsDirectoryForApp $idpssDirectory $idpssIisUser.UserName

Register-ServiceWithDiscovery -iisUserName $idpssIisUser.UserName -metadataConnStr $metadataDatabase.DbConnectionString -version $idpssInstallApplication.version -serverUrl "$idpssServiceUrl/v1" `
-serviceName $idpssConfigStore.appName -friendlyName "Fabric.IdentityProviderSearchService" -description "The Fabric.IdentityProviderSearchService searches Identity Providers for matching users and groups.";

$idpssConfig = $idpssDirectory + "\web.config"
Write-Host "IdPSS Web Config: $($idpssConfig)"

$useWindows = $identityConfigStore.useWindowsAD
if($null -eq $useWindows) {
    $useWindows = $true
    Add-InstallationSetting -configSection $identitySettingsScope -configSetting "useWindowsAD" -configValue "$useWindows" -installConfigPath $configStore.Path  | Out-Null
}

$idpssName = $Global:idPSSAppName

Set-IdentityProviderSearchServiceWebConfigSettings -webConfigPath $idpssConfig `
    -useAzure $useAzure `
    -useWindows $useWindows `
    -installConfigPath $configStore.Path `
    -azureSettingsConfigPath $azureConfigStore.Path `
    -encryptionCert $certificates.SigningCertificate `
    -encryptionCertificateThumbprint $certificates.EncryptionCertificate.Thumbprint `
    -appInsightsInstrumentationKey $appInsightsKey `
    -appName $idpssName 