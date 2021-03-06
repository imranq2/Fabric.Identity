$targetFilePath = "$PSScriptRoot\Install-Identity-Utilities.psm1"
Import-Module -Name $targetFilePath -Force

# Import AzureAD
$minVersion = [System.Version]::new(2, 0, 2 , 4)
$azureAD = Get-Childitem -Path ./**/AzureAD.psm1 -Recurse
if ($azureAD.length -eq 0) {
    # Do not show error when AzureAD is not installed, will install instead
    $installed = Get-InstalledModule -Name AzureAD -ErrorAction "silentlycontinue"

    if (($null -eq $installed) -or ($installed.Version.CompareTo($minVersion) -lt 0)) {
        Write-Host "Installing AzureAD from Powershell Gallery"
        Install-Module AzureAD -Scope CurrentUser -MinimumVersion $minVersion -Force
        Import-Module AzureAD -Force
    }
}
else {
    Write-Host "Installing AzureAD at $($azureAD.FullName)"
    Import-Module -Name $azureAD.FullName
}

function Get-GraphApiPermissionFromList() {
    param(
        [string] $permissionName,
        [string] $type,
        [Microsoft.Open.AzureAD.Model.ServicePrincipal] $servicePrincipal
    )
    if($type -eq "scope") {
        $permission = $servicePrincipal.Oauth2Permissions | Where-Object {$_.Value -eq $permissionName}
        if($null -eq $permission) {
            Write-DosMessage -Level "Fatal" -Message "Was not able to find permissions $permissionName."
        }
    } elseif($type -eq "role") {        
        $permission = $servicePrincipal.AppRoles | Where-Object {$_.Value -eq $permissionName}
        if($null -eq $permission) {
            Write-DosMessage -Level "Fatal" -Message "Was not able to find permissions $permissionName."
        }
    } else {
        Write-DosMessage -Level "Fatal" -Message "Invalid type was passed: $type. Expected type of 'scope' or 'role'."
    }
    

    return $permission
}

function Get-GraphiApiUserDirectoryReadPermissions() {
    try {
        $aad = @((Get-AzureADServicePrincipal -Filter "ServicePrincipalNames eq 'https://graph.microsoft.com'"))[0]
    }
    catch {
        Write-DosMessage -Level "Error" -Message "Was not able to get the Microsoft Graph API service principal."
        throw
    }

    # Get Permissions
    $userReadPermission = Get-GraphApiPermissionFromList -permissionName "User.Read" -type "Scope" -servicePrincipal $aad
    $directoryReadPermission = Get-GraphApiPermissionFromList -permissionName "Directory.Read.All" -type "Role" -servicePrincipal $aad

    # Construct expected RequiredResourceAccess object
    $userDirectoryReadRequiredResourceAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $userReadResourceAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList $userReadPermission.Id,"Scope"
    $directoryReadResourceAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList $directoryReadPermission.Id,"Role"

    $userDirectoryReadRequiredResourceAccess.ResourceAppId = $aad.AppId
    $userDirectoryReadRequiredResourceAccess.ResourceAccess = $userReadResourceAccess,$directoryReadResourceAccess

    return $userDirectoryReadRequiredResourceAccess
}

function Get-GraphApiDirectoryReadPermissions() {
    try {
        $aad = @((Get-AzureADServicePrincipal -Filter "ServicePrincipalNames eq 'https://graph.microsoft.com'"))[0]
    }
    catch {
        Write-DosMessage -Level "Error" -Message "Was not able to get the Microsoft Graph API service principal."
        throw
    }

    $directoryReadName = "Directory.Read.All"
    $directoryRead = Get-GraphApiPermissionFromList -permissionName $directoryReadName -type "Role" -servicePrincipal $aad

    # Convert to proper resource...
    $readAccess = [Microsoft.Open.AzureAD.Model.RequiredResourceAccess]@{
        ResourceAppId = $aad.AppId;
        ResourceAccess = [Microsoft.Open.AzureAD.Model.ResourceAccess]@{
            Id = $directoryRead.Id;
            Type = "Role"
        }
    }

    return $readAccess
}


function Get-GraphApiUserReadPermissions() {
    try {
        $aad = @((Get-AzureADServicePrincipal -Filter "ServicePrincipalNames eq 'https://graph.microsoft.com'"))[0]
    }
    catch {
        Write-DosMessage -Level "Error" -Message "Was not able to get the Microsoft Graph API service principal."
        throw
    }

    $userReadName = "User.Read"
    $userRead = Get-GraphApiPermissionFromList -permissionName $userReadName -servicePrincipal $aad

    # Convert to proper resource...
    $readAccess = [Microsoft.Open.AzureAD.Model.RequiredResourceAccess]@{
        ResourceAppId = $aad.AppId;
        ResourceAccess = [Microsoft.Open.AzureAD.Model.ResourceAccess]@{
            Id = $userRead.Id;
            Type = "Scope"
        }
    }

    return $readAccess
}

function New-FabricAzureADApplication() {
    param(
        [Parameter(Mandatory=$true)]
        [string] $appName,
        [Parameter(Mandatory=$true)]
        [Hashtable[]] $replyUrls,
        [Microsoft.Open.AzureAD.Model.RequiredResourceAccess] $permissions,
        [bool] $isMultiTenant = $false
    )
    $groupMembershipClaims = 'SecurityGroup'

    $app = Get-AzureADApplication -Filter "DisplayName eq '$appName'" -Top 1
    if($null -eq $app) {
        $app = New-AzureADApplication -Oauth2AllowImplicitFlow $true -RequiredResourceAccess $permissions -DisplayName $appName -ReplyUrls $replyUrls.name -AvailableToOtherTenants $isMultiTenant -GroupMembershipClaims $groupMembershipClaims
    }
    else {
        # Do not overwrite, append to existing urls
        # Updating app fails if trying to add duplicate urls
        $existingUrls = $app.ReplyUrls
        foreach($replyUrl in $replyUrls.name) {
            $existingUrls.Add($replyUrl)
        }
        $existingUrls = $existingUrls | Select-Object -Unique

        # Do not overwrite, append existing permissions
        # Existing permissions might be an array of required resourceaccess
        $combinedResources = Get-CombinedAzureADPermissions `
            -existingRequiredResourceAccess $app.RequiredResourceAccess `
            -newRequiredResourceAccess $permissions

        Set-AzureADApplication -ObjectId $app.ObjectId -RequiredResourceAccess $combinedResources -Oauth2AllowImplicitFlow $true -ReplyUrls $existingUrls -AvailableToOtherTenants $isMultiTenant -GroupMembershipClaims $groupMembershipClaims
    }

    return $app
}

function Get-CombinedAzureADPermissions {
    param (
        [Parameter(Mandatory=$true)]
        [Microsoft.Open.AzureAD.Model.RequiredResourceAccess[]] $existingRequiredResourceAccess,
        [Parameter(Mandatory=$true)]
        [Microsoft.Open.AzureAD.Model.RequiredResourceAccess] $newRequiredResourceAccess
    )
    # Need to ignore values if already exists!
    foreach($rra in $existingRequiredResourceAccess) {
        # IF Match, then append to the list and exit
        if($rra.ResourceAppId -eq $newRequiredResourceAccess.ResourceAppId) {
            $rra.ResourceAccess += $newRequiredResourceAccess.ResourceAccess
            $rra.ResourceAccess = $rra.ResourceAccess | Select-Object -Unique
            return $existingRequiredResourceAccess
        }
    }

    Write-DosMessage -Level "Information" -Message "Did not find any existing permissions to merge."
    return $newRequiredResourceAccess
}

function Remove-AzureADClientSecret {
    param(
        [string] $objectId,
        [string] $keyIdentifier
    )
    $encoding = [System.Text.Encoding]::ASCII
    $keys = Get-AzureADApplicationPasswordCredential -ObjectId $objectId
    $filteredKeys = $keys | Where-Object {$null -ne $_.CustomKeyIdentifier -and $encoding.GetString($_.CustomKeyIdentifier) -eq $keyIdentifier}
    $completed = $false
    $deleteSecrets = $false
    [int]$retryCount = 0

    if ($filteredKeys.count -gt 0) {
        $deleteSecrets = Get-InstallIdPSSUtilsUserConfirmation -keyName $keyIdentifier
    }

    if($deleteSecrets) {
        foreach($key in $filteredKeys) {
            Write-Host "Removing existing password credential named `"$($encoding.GetString($key.CustomKeyIdentifier))`" with id $($key.KeyId)"
            do {
                if($retryCount -gt 3) {
                    Write-DosMessage -Level "Fatal" -Message "Could not create Azure AD application secret."
                }

                try {
                    Remove-AzureADApplicationPasswordCredential -ObjectId $objectId -KeyId $key.KeyId -ErrorAction 'stop'
                    $completed = $true
                }
                catch {
                    Write-DosMessage -Level "Warning" -Message "An error occurred trying to remove the Azure application secret named `"$($encoding.GetString($key.CustomKeyIdentifier))`" with id $($key.KeyId). Retrying.."
                    Start-Sleep 3
                    $retryCount++
                }
            } while ($completed -eq $false)
        }
    }
}

function Get-FabricAzureADSecret {
    param(
        [string] $objectId,
        [string] $secretName
    )
    $keyCredentialName = $secretName

    # Cleanup existing secret
    Remove-AzureADClientSecret -objectId $objectId -keyIdentifier $keyCredentialName

    Write-Host "Creating password credential named $keyCredentialName"
    $completed = $false
    [int]$retryCount = 0

    do{
        if($retryCount -gt 3) {
            Write-DosMessage -Level "Error" -Message "Could not create Azure AD application secret."
            throw
        }

        try {
            $credential = New-AzureADApplicationPasswordCredential -ObjectId $objectId -CustomKeyIdentifier $keyCredentialName -ErrorAction 'stop'
            $completed = $true
        }
        catch {
            Write-DosMessage -Level "Warning" -Message "An error occurred trying to create the Azure application secret named $keyCredentialName. Retrying.."
            Start-Sleep 3
            $retryCount++
        }
    } While ($completed -eq $false)
    return $credential.Value
}

function Connect-AzureADTenant {
    param(
        [Parameter(Mandatory=$true)]
        [string] $tenantId,
        [PSCredential] $credential
    )

    try {
        if($credential) {
            Connect-AzureAD -Credential $credential -TenantId $tenantId | Out-Null
        } else {
            Connect-AzureAD -TenantId $tenantId | Out-Null
        }
    }
    catch {
        Write-DosMessage -Level "Error" -Message  "Could not sign into tenant '$tenantId' with user '$($credential.UserName)'"
        throw
    }
}

function Get-Tenants {
    param(
        [string] $azureConfigPath
    )
    $tenants = @()
    $scope = "identity"
    $parentSetting = "tenants"
    $tenants += Get-TenantSettingsFromInstallConfig -installConfigPath $azureConfigPath `
        -scope $scope `
        -setting $parentSetting

    if($null -eq $tenants -or $tenants.Count -eq 0){
        Write-DosMessage -Level "Error" -Message  "No tenants to register were found in the install.config"
        throw
    }
    Confirm-Tenants $tenants

    return $tenants
}

function Get-ReplyUrls {
    param(
        [string] $azureConfigPath
    )
    $scope = "identity"
    $parentSetting = "replyUrls"
    $replyUrls = @()
    $replyUrls += Get-TenantSettingsFromInstallConfig -installConfigPath $azureConfigPath -scope $scope -setting $parentSetting

    if($null -eq $replyUrls -or $replyUrls.Count -eq 0){
        Write-DosMessage -Level "Error" -Message  "No reply urls where found in the install.config."
        throw
    }

    return $replyUrls
}

function Register-Identity {
    param(
        [Parameter(Mandatory=$true)]
        [string] $appName,
        [Parameter(Mandatory=$true)]
        [HashTable[]] $replyUrls,
        [Parameter(Mandatory=$true)]
        [string] $configSection,
        [Parameter(Mandatory=$true)]
        [string] $azureConfigPath,
        [string] $configAppName = "Identity Service",
        [string] $identitySearchAppName = "Identity Service Search"
    )

    $installSettings = Get-XMLChildNode -installConfigPath $azureConfigPath -configSection $configSection -childNodeGetAttribute "name" -childNodeAttributeSetting "azureSecretName"
    $secretName = $installSettings.value
    Confirm-InstallIdpSSUtilsSecretName -secretName $secretName

    $allowedTenantsText = "allowedTenants"

    $claimsIssuer = Get-IdentityClaimsIssuer -azureConfigPath $azureConfigPath -configSection $configSection
    $allowedTenants += Get-TenantSettingsFromInstallConfig -installConfigPath $azureConfigPath `
        -scope $configSection `
        -setting $allowedTenantsText

    Confirm-Tenants -tenants $allowedTenants
    Confirm-Tenants -tenants $claimsIssuer

    # Register authentication portion as claims issuer
    if($null -ne $claimsIssuer.name) {
        Write-Host "Enter credentials for $appName specified tenant: $($claimsIssuer.name)"
        Connect-AzureADTenant -tenantId $claimsIssuer.name

        $userDirectoryReadPermissions = Get-GraphiApiUserDirectoryReadPermissions
        $app = New-FabricAzureADApplication -appName $appName -replyUrls $replyUrls -permissions $userDirectoryReadPermissions -isMultiTenant $true
        $clientId = $app.AppId
        $clientSecret = Get-FabricAzureADSecret -objectId $app.ObjectId -secretName $secretName

        Disconnect-AzureAD

        # Add Identity Service to AppRegistrations Section
        Add-InstallationTenantSettings -configSection $configSection `
        -tenantId $claimsIssuer.name `
        -tenantAlias $claimsIssuer.alias `
        -clientSecret $clientSecret `
        -clientId $clientId `
        -installConfigPath $azureConfigPath `
        -appName $configAppName

        # Add Identity Service Search to AppRegistrations Section
        Add-InstallationTenantSettings -configSection $configSection `
        -tenantId $claimsIssuer.name `
        -tenantAlias $claimsIssuer.alias `
        -clientSecret $clientSecret `
        -clientId $clientId `
        -installConfigPath $azureConfigPath `
        -appName $identitySearchAppName

        # Manual process, need to give consent this way for now
        Start-Process -FilePath  "https://login.microsoftonline.com/$($claimsIssuer.name)/oauth2/authorize?client_id=$clientId&response_type=code&state=12345&prompt=admin_consent"
    }
    else
    {
        Write-DosMessage -Level "Information" -Message "No claims issuer tenant was found in the azuresettings.config."
    }
}

function Register-IdPSS {
    param (
        [Parameter(Mandatory=$true)]
        [string] $appName,
        [Parameter(Mandatory=$true)]
        [HashTable[]] $replyUrls,
        [Parameter(Mandatory=$true)]
        [HashTable[]] $tenants,
        [Parameter(Mandatory=$true)]
        [string] $configSection,
        [Parameter(Mandatory=$true)]
        [string] $azureConfigPath,
        [string] $configAppName = "Identity Service Search"
    )
    $installSettings = Get-XMLChildNode -installConfigPath $azureConfigPath -configSection $configSection -childNodeGetAttribute "name" -childNodeAttributeSetting "azureSecretName"
    $secretName = $installSettings.value
    Confirm-InstallIdpSSUtilsSecretName -secretName $secretName

    # IdentityProviderSearchService registration
   if($null -ne $tenants) {
    foreach($tenant in $tenants) { 
      Write-Host "Enter credentials for $appName on tenant specified: $($tenant.name)"
      Connect-AzureADTenant -tenantId $tenant.name

      # Get read permissions
      $permissions = Get-GraphApiDirectoryReadPermissions
      $app = New-FabricAzureADApplication -appName $appName -replyUrls $replyUrls -permissions $permissions
      $clientId = $app.AppId
      $clientSecret = Get-FabricAzureADSecret -objectId $app.ObjectId -secretName $secretName

      Disconnect-AzureAD
      Add-InstallationTenantSettings -configSection $configSection `
          -tenantId $tenant.name `
          -tenantAlias $tenant.alias `
          -clientSecret $clientSecret `
          -clientId $clientId `
          -installConfigPath $azureConfigPath `
          -appName $configAppName

      # Manual process, need to give consent this way for now
      Start-Process -FilePath  "https://login.microsoftonline.com/$($tenant.name)/oauth2/authorize?client_id=$clientId&response_type=code&state=12345&prompt=admin_consent"
    }
 }
}

function Confirm-InstallIdpSSUtilsSecretName {
    param(
        [string] $secretName
    )

    if([string]::IsNullOrEmpty($secretName)) {
        Write-DosMessage -Level "Fatal" -Message "A Secret Name for registering with Azure must be provided:`n <variable name=`"secretName`" value=`"Name`">"
    }
}

function Confirm-Tenants {
    param(
        [Parameter(Mandatory=$true)]
        [Object[]] $tenants
    )
    foreach($tenant in $tenants) {
        if([string]::IsNullOrEmpty($tenant.name) -or [string]::IsNullOrEmpty($tenant.alias)) {
            Write-DosMessage -Level "Fatal" -Message "Tenant alias and name must be provided for each tenant."
        }
    }
}

function Get-InstallIdPSSUtilsUserConfirmation {
    param (
        [string] $keyName
    )
    Write-DosMessage -Level "Information" -Message "Found duplicate secrets."
    $deleteSecrets = Read-Host  "Delete duplicate secret(s) named: '$keyName'? [Y/N]"
    switch ($deleteSecrets) {
        Y {return $true}
        N {return $false}
        Default {return $false}
    }
}

function Get-XMLChildNode {
    param (
        [Parameter(Mandatory=$true)]
        [string] $installConfigPath,
        [Parameter(Mandatory=$true)]
        [string] $configSection,
        [Parameter(Mandatory=$true)]
        [string] $childNodeGetAttribute,
        [Parameter(Mandatory=$true)]
        [string] $childNodeAttributeSetting
    )
    # Validate XML
    $xmlValidation = Test-XMLFile -Path $installConfigPath
    if($xmlValidation){
     $installationConfig = [xml](Get-Content $installConfigPath)
     $identityScope = $installationConfig.installation.settings.scope | Where-Object {$_.name -eq $configSection}
     $existingChildNode = @()

     $existingChildNode += $identityScope.ChildNodes | Where-Object {$_.$childNodeGetAttribute -eq $childNodeAttributeSetting}
     if ($null -eq $existingChildNode)
     {
       Write-DosMessage -Level "Information" -Message "$childNodeAttributeSetting not found"
     }
     return $existingChildNode
    }
}

function Get-IdentityClaimsIssuer {
    param (
        [Parameter(Mandatory=$true)]
        [string] $azureConfigPath,
        [Parameter(Mandatory=$true)]
        [string] $configSection
    )

    $claimsIssuerSetting = "claimsIssuerTenant"
    $claimsIssuer = @()
    $claimsIssuer += Get-TenantSettingsFromInstallConfig `
        -installConfigPath $azureConfigPath `
        -scope $configSection `
        -setting $claimsIssuerSetting

    if($null -eq $claimsIssuer -or $claimsIssuer.Count -eq 0) {
        Write-DosMessage -Level "Fatal" -Message "No claims issuer tenant was found in the azuresettings.config."
    } 
    else {
        if($claimsIssuer.Count -gt 1) {
            Write-DosMessage -Level "Fatal" -Message "Multiple claims issuer tenants were found in the azuresettings.config. Please provide only one claims issuer."
        }
        return $claimsIssuer[0]
    }
}

function Remove-IdentityClaimsIssuerFromTenantsList {
    param (
        [Parameter(Mandatory=$true)]
        [HashTable[]] $tenants,
        [Parameter(Mandatory=$true)]
        [string] $claimsIssuerName
    )
    [System.Collections.ArrayList]$tenantsList = $tenants
    foreach($tenant in $tenantsList) {
        if($tenant.Name -eq $claimsIssuerName) {
            $tenantsList.Remove($tenant)
            return $tenantsList.ToArray()
        }
    }
    return $tenantsList.ToArray()
}

Export-ModuleMember Get-FabricAzureADSecret
Export-ModuleMember Connect-AzureADTenant
Export-ModuleMember New-FabricAzureADApplication
Export-ModuleMember Get-Tenants
Export-ModuleMember Get-ReplyUrls
Export-ModuleMember Register-Identity
Export-ModuleMember Register-IdPSS
Export-ModuleMember Get-IdentityClaimsIssuer
Export-ModuleMember Remove-IdentityClaimsIssuerFromTenantsList
Export-ModuleMember Get-GraphApiUserReadPermissions
Export-ModuleMember Get-GraphApiDirectoryReadPermissions