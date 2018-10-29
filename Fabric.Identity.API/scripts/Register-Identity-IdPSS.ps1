Import-Module -Name $PSScriptRoot\Install-IdPSS-Utilities.psm1 -Force

$installConfigPath = "$PSScriptRoot\registration.config"

$installSettings = Get-InstallationConfig -installConfigPath $installConfigPath
#$tenants = $installSettings.registration.settings.tenants.variable
$commonScope = $installSettings.installation.settings.scope | Where-Object {$_.name -eq "common"}
$tenants = $commonScope.tenants.variable


# TODO: Differentiate between idpss and identity application for extra permissions
if($null -ne $tenants) {
    foreach($tenant in $tenants.name) {
        Write-Host "Enter credentials for specified tenant $tenant"
        $credential = Get-Credential

        #New-FabricAzureADApplicationRegistration -tenantId $tenant -credentials $credential

        Connect-AzureADTenant -tenantId $tenant -credentials $credential
        $app = New-FabricAzureADApplication
        $clientId = $app.AppId
        $clientSecret = Get-FabricAzureADSecret -objectId $app.ObjectId

        Disconnect-AzureAD

        Add-InstallationConfigSetting $tenant $clientSecret $clientId $installConfigPath

        # Manual process, need to give consent this way for now
        #Start-Process -FilePath  "https://login.microsoftonline.com/$tenantId/oauth2/authorize?client_id=$clientId&response_type=code&state=12345&prompt=admin_consent"
    }
}