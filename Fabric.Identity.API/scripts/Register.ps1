#
# Register.ps1
#
function Get-IdentityServiceUrl()
{
    return "https://$env:computername.$($env:userdnsdomain.tolower())/Identity"
}

function Get-AuthorizationServiceUrl()
{
    return "https://$env:computername.$($env:userdnsdomain.tolower())/Authorization"
}

function Get-DiscoveryServiceUrl()
{
    return "https://$env:computername.$($env:userdnsdomain.tolower())/DiscoveryService"
}

function Get-ApplicationUrl($serviceName, $discoveryServiceUrl){
    $discoveryRequest = "$discoveryServiceUrl/v1/Services?`$filter=ServiceName eq '$serviceName'&`$select=ServiceUrl&`$orderby=Version desc"
    $discoveryResponse = Invoke-RestMethod -Method Get -Uri $discoveryRequest -UseDefaultCredentials
    $serviceUrl = $discoveryResponse.value.ServiceUrl
    if([string]::IsNullOrWhiteSpace($serviceUrl)){
        Write-Error "The service $serviceName is not registered with the Discovery service. Make sure that the service is registered w/ Discovery service before proceeding. Halting installation." -ErrorAction Stop
    }
    return $serviceUrl
}

function Invoke-Get($url, $accessToken)
{
    $headers = @{"Accept" = "application/json"}
    if($accessToken){
        $headers.Add("Authorization", "Bearer $accessToken")
    }
        
    $getResponse = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
    return $getResponse
}

function Invoke-Put($url, $body, $accessToken)
{
    $headers = @{"Accept" = "application/json"}
    if($accessToken){
        $headers.Add("Authorization", "Bearer $accessToken")
    }
    if(!($body -is [String])){
        $body = (ConvertTo-Json $body)
    }
    try{
        $putResponse = Invoke-RestMethod -Method Put -Uri $url -Body $body -ContentType "application/json" -Headers $headers
        Write-Success "Success."
        Write-Host ""
        return $putResponse
    }catch{
        $exception = $_.Exception
        $error = Get-ErrorFromResponse -response $exception.Response
        Write-Error "There was an error updating the resource: $error. Halting installation."
        throw $exception
    }
}

function Invoke-Post($url, $body, $accessToken)
{
    $headers = @{"Accept" = "application/json"}
    if($accessToken){
        $headers.Add("Authorization", "Bearer $accessToken")
    }
    if(!($body -is [String])){
        $body = (ConvertTo-Json $body)
    }
    try{
        $postResponse = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType "application/json" -Headers $headers
        Write-Success "Success."
        Write-Host ""
        return $postResponse
    }catch{
        $exception = $_.Exception
        $error = Get-ErrorFromResponse -response $exception.Response
        Write-Error "There was an error adding the resource: $error. Halting installation."
        throw $exception
    }
}

function Get-ErrorFromResponse($response)
{
    $result = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($result)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $responseBody = $reader.ReadToEnd();
    return $responseBody
}

function Add-AuthorizationRegistration($authUrl, $clientId, $clientName, $accessToken)
{
    $url = "$authUrl/clients"
    $body = @{
        id = "$clientId"
        name = "$clientName"
    }
    return Invoke-Post $url $body $accessToken
}

function Add-Permission($authUrl, $name, $grain, $securableItem, $accessToken)
{
    $url = "$authUrl/permissions"
    $body = @{
        name = "$name"
        grain = "$grain"
        securableItem = "$securableItem"
    }
    $permission = Invoke-Post $url $body $accessToken
    return $permission
}

function Add-Role($authUrl, $name, $grain, $securableItem, $accessToken)
{
    $url = "$authUrl/roles"
    $body = @{
        name = "$name"
        grain = "$grain"
        securableItem = "$securableItem"
    }
    $role = Invoke-Post $url $body $accessToken
    return $role
}

function Add-Group($authUrl,$name, $source, $accessToken)
{
    $url = "$authUrl/groups"
    $body = @{
        id = "$name"
        groupName = "$name"
        groupSource = "$source"
    }
    return Invoke-Post $url $body $accessToken
}

function Add-PermissionToRole($authUrl, $roleId, $permission, $accessToken)
{
    $url = "$authUrl/roles/$roleId/permissions"
    $body = @($permission)
    return Invoke-Post $url $body $accessToken
}

function Add-RoleToGroup($authUrl, $groupName, $role, $accessToken)
{
    $encodedGroupName = [System.Web.HttpUtility]::UrlEncode($groupName)
    $url = "$authUrl/groups/$encodedGroupName/roles"
    $body = $role
    return Invoke-Post $url $body $accessToken
}

function Test-IsApiRegistered($identityServiceUrl, $apiName, $accessToken){
    $apiExists = $false
    $url = "$identityServiceUrl/api/apiresource/$apiName"

    try{
        $getResponse = Invoke-Get -url $url -accessToken $accessToken
        $apiExists = $true
        return $apiExists
    }catch{
        $exception = $_.Exception
        if($exception -ne $null -and $exception.Response.StatusCode.value__ -ne 404)
        {
            $error = Get-ErrorFromResponse($exception.Response)
            Write-Error $error
            throw $exception
        }
        return $apiExists
    }
}

function Test-IsClientRegistered($identityServiceUrl, $clientId, $accessToken){
    $clientExists = $false
    $url = "$identityServiceUrl/api/client/$clientId"

    try{
        $getResponse = Invoke-Get -url $url -accessToken $accessToken
        $clientExists = $true
        return $clientExists
    }catch{
        $exception = $_.Exception
        if($exception -ne $null -and $exception.Response.StatusCode.value__ -ne 404)
        {
            $error = Get-ErrorFromResponse($exception.Response)
            Write-Error $error
            throw $exception
        }
        return $clientExists
    }
}

function Invoke-UpdateApiRegistration($identityServiceUrl, $body, $apiName, $accessToken){
    $url = "$identityServiceUrl/api/apiresource/$apiName"
    Write-Host $url
    Write-Host $body
    $response = Invoke-Put -url $url -body $body -accessToken $accessToken
}

function Invoke-UpdateClientRegistration($identityServiceUrl, $body, $clientId, $accessToken){
    $url = "$identityServiceUrl/api/client/$clientId"
    $response = Invoke-Put -url $url -body $body -accessToken $accessToken
}

function Get-RegistrationSettings()
{
    Write-Host "Getting registration settings"
    $registrationConfig = [xml](Get-Content registration.config)
    if($registrationConfig -eq $null){
        Write-Host "No registration content"
    }
    return $registrationConfig.registration
}

function Get-ApiResourcesToRegister($registrationConfig)
{
    if($registrationConfig -eq $null){
        Write-Host "registration config is null"
    }
    $apiResources = $registrationConfig.apiresources
    return $apiResources.api
}

function Get-ClientsToRegister($registrationConfig)
{
    $clients = $registrationConfig.clients
    return $clients.client
}

function Get-RolesAndPermissionsToRegister($registrationConfig){
    $authorization = $registrationConfig.authorization
    return $authorization
}

function Get-ApiResourceFromConfig($api){
    $body = @{
            name = $api.name
            scopes = @()
            userClaims = @()
        }

        foreach($scope in $api.scopes.scope){
            $body.scopes += @{name =$scope }
        }

        foreach($claim in $api.userClaims.claim){
            $body.userClaims += $claim
        }
    return $body
}

function Get-ImplicitClientFromConfig($client, $discoveryServiceUrl){
    $implicitBody = @{
        requireConsent = $false
        allowOfflineAccess = $false
        allowAccessTokensViaBrowser = $true
        enableLocalLogin =$false
        accessTokenLifetime = 1200
        allowedCorsOrigins = @()
        redirectUris = @()
        postLogoutRedirectUris = @()
    }
    
    $atlasUrl = Get-ApplicationUrl -serviceName $client.serviceName -discoveryServiceUrl $discoveryServiceUrl

    foreach($allowedCorsOrigin in $client.allowedCorsOrigins.corsOrigin){
        $implicitBody.allowedCorsOrigins += [string]::Format($allowedCorsOrigin, $atlasUrl)
    }

    foreach($redirectUri in $client.redirectUris.redirectUri){
        $implicitBody.redirectUris += [string]::Format($redirectUri, $atlasUrl)
    }

    foreach($redirectUri in $client.postLogoutRedirectUris.redirectUri){
        $implicitBody.postLogoutRedirectUris += [string]::Format($redirectUri, $atlasUrl)
    }
    
    return $implicitBody
}

function Get-ClientFromConfig($client, $discoveryServiceUrl){
    $body = @{
            clientId = $client.clientid
            clientName = $client.clientName
            allowedScopes = @()
            allowedGrantTypes = @()
        }
    
        foreach($scope in $client.allowedScopes.scope){
            $body.allowedScopes += $scope
        }

        foreach($grantType in $client.allowedGrantTypes.grantType){
            $body.allowedGrantTypes += $grantType
        }

    if($body.allowedGrantTypes.Contains("implicit")){
        $implicitBody = Get-ImplicitClientFromConfig -client $client -body $body -discoveryServiceUrl $discoveryServiceUrl
        $body = $implicitBody + $body
    }

    return $body
}

function Invoke-RegisterApiResources($apiResources, $identityServiceUrl, $accessToken)
{
    Write-Host "registering apis"
    if($apiResources -eq $null){
        Write-Host "no api resources"
    }
    foreach($api in $apiResources){
        Write-Host "registering $($api.name)"
        $body = Get-ApiResourceFromConfig($api)
        $isApiRegistered = Test-IsApiRegistered -identityServiceUrl $identityServiceUrl -apiName $api.name -accessToken $accessToken
        
        if($isApiRegistered){
            Write-Host "API is registered, updating"
            #$apiSecret = Invoke-UpdateApiRegistration -identityServiceUrl $identityServiceUrl -body $body -apiName $api.name -accessToken $accessToken
        }else{
            Write-Host "API is not registered, adding"
            $apiSecret = Add-ApiRegistration -authUrl $identityServiceUrl -body (ConvertTo-Json $body) -accessToken $accessToken
        }
    }
}

function Invoke-RegisterClients($clients, $identityServiceUrl, $accessToken, $discoveryServiceUrl)
{
    Write-Host "registering clients"
    if($clients -eq $null){
        Write-Host "no clients to register"
    }
    foreach($client in $clients){
        Write-Host "registering $($client.clientid)"
        $body = Get-ClientFromConfig -client $client -discoveryServiceUrl $discoveryServiceUrl
        $isClientRegistered = Test-IsClientRegistered -identityServiceUrl $identityServiceUrl -clientId $client.clientid -accessToken $accessToken

        if($isClientRegistered){
            Write-Host "Client is registered, updating"
            $clientSecret = Invoke-UpdateClientRegistration -identityServiceUrl $identityServiceUrl -body $body -clientId $client.clientid -accessToken $accessToken
        }else{
            Write-Host "Client is not registered, adding"
            $jsonBody = ConvertTo-Json $body
            $clientSecret = Add-ClientRegistration -authUrl $identityServiceUrl -body $jsonBody -accessToken $accessToken 
        }
    }
}

function Invoke-RegisterRolesAndPermissions($rolesAndPermissions, $identityServiceUrl, $accessToken){
    Write-Host "registering roles and permissions"
    if($authorization -eq $null){
        Write-Host "No roles and permissions to register"
    }
    foreach($grain in $authorization.grain){
        $grainName = $grain.name
        foreach($secureableItem in $grain.secureableItem){
            $secureableItemName = $secureableItem.name
            foreach($role in $secureableItem.role){
                $roleName = $role.name
                Write-Host "Adding role: $roleName for grain: $grainName and secureableItem: $secureableItemName"
                $addedRole = Add-Role -authUrl $authorizationServiceURL -name $roleName -grain $grainName -securableItem $secureableItemName -accessToken $accessToken
                foreach($permission in $role.permission){
                    $permissionName = $permission.name
                    Write-Host "Adding permission: $permissionName for grain: $grainName and securableItem: $secureableItemName"
                    $addedPermission = Add-Permission -authUrl $authorizationServiceURL -name $permissionName -grain $grainName -securableItem $secureableItemName -accessToken $accessToken
                    Write-Host "Associating permission: $permissionName with role: $roleName"
                    $rolePermission = Add-PermissionToRole -authUrl $authorizationServiceURL -roleId $addedRole.id -permission $addedPermission -accessToken $accessToken
                }
            }
        }
    }
}

if(!(Test-Path .\Fabric-Install-Utilities.psm1)){
	Invoke-WebRequest -Uri https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/common/Fabric-Install-Utilities.psm1 -OutFile Fabric-Install-Utilities.psm1
}
Import-Module -Name .\Fabric-Install-Utilities.psm1 -Force

if(!(Test-IsRunAsAdministrator))
{
    Write-Error "You must run this script as an administrator. Halting configuration." -ErrorAction Stop
}

$installSettings = Get-InstallationSettings "identity"
$fabricInstallerSecret = $installSettings.fabricInstallerSecret
$discoveryServiceUrl = $installSettings.discoveryService
$authorizationServiceURL =  $installSettings.authorizationService
$identityServiceUrl = $installSettings.identityService

if([string]::IsNullOrEmpty($installSettings.identityService))  
{
	$identityServiceUrl = Get-IdentityServiceUrl
} else
{
	$identityServiceUrl = $installSettings.identityService
}

if([string]::IsNullOrEmpty($installSettings.authorizationService))  
{
	$authorizationServiceURL = Get-AuthorizationServiceUrl
} else
{
	$authorizationServiceURL = $installSettings.authorizationService
}

if([string]::IsNullOrEmpty($installSettings.discoveryService))  
{
	$discoveryServiceUrl = Get-DiscoveryServiceUrl
} else
{
	$discoveryServiceUrl = $installSettings.discoveryService
}

try{
	$encryptionCert = Get-Certificate $encryptionCertificateThumbprint
}catch{
	Write-Host "Could not get encryption certificate with thumbprint $encryptionCertificateThumbprint. Please verify that the encryptionCertificateThumbprint setting in install.config contains a valid thumbprint for a certificate in the Local Machine Personal store. Halting installation."
	throw $_.Exception
}

$userEnteredFabricInstallerSecret = Read-Host  "Enter the Fabric Installer Secret or hit enter to accept the default [$fabricInstallerSecret]"
Write-Host ""
if(![string]::IsNullOrEmpty($userEnteredFabricInstallerSecret)){   
     $fabricInstallerSecret = $userEnteredFabricInstallerSecret
}

$userEnteredDiscoveryServiceUrl = Read-Host  "Enter the URL for the Discovery Service or hit enter to accept the default [$discoveryServiceUrl]"
Write-Host ""
if(![string]::IsNullOrEmpty($userEnteredDiscoveryServiceUrl)){   
     $discoveryServiceUrl = $userEnteredDiscoveryServiceUrl
}

$userEnteredAuthorizationServiceURL = Read-Host  "Enter the URL for the Authorization Service or hit enter to accept the default [$authorizationServiceURL]"
Write-Host ""
if(![string]::IsNullOrEmpty($userEnteredAuthorizationServiceURL)){   
     $authorizationServiceURL = $userEnteredAuthorizationServiceURL
}

$userEnteredIdentityServiceURL = Read-Host  "Enter the URL for the Identity Service or hit enter to accept the default [$identityServiceUrl]"
Write-Host ""
if(![string]::IsNullOrEmpty($userEnteredIdentityServiceURL)){   
     $identityServiceUrl = $userEnteredIdentityServiceURL
}

if([string]::IsNullOrWhiteSpace($fabricInstallerSecret))
{
    Write-Error "You must enter a value for the installer secret" -ErrorAction Stop
}
if([string]::IsNullOrWhiteSpace($authorizationServiceURL))
{
    Write-Error "You must enter a value for the Fabric.Authorization URL" -ErrorAction Stop
}
if([string]::IsNullOrWhiteSpace($identityServiceUrl))
{
    Write-Error "You must enter a value for the Fabric.Identity URL." -ErrorAction Stop
}
if([string]::IsNullOrWhiteSpace($discoveryServiceUrl))
{
    Write-Error "You must enter a value for the Discovery Service URL." -ErrorAction Stop
}

# Get the installer access token
$accessToken = Get-AccessToken $identityServiceUrl "fabric-installer" "fabric/identity.manageresources fabric/authorization.write fabric/authorization.read fabric/authorization.dos.write fabric/authorization.manageclients" $fabricInstallerSecret

# Read the registration.config file
$registrationSettings = Get-RegistrationSettings

# Register API Resources specified in the registration.config file
$apiResources = Get-ApiResourcesToRegister -registrationConfig  $registrationSettings
Invoke-RegisterApiResources -apiResources $apiResources -identityServiceUrl $identityServiceUrl -accessToken $accessToken

# Register the Clients specified in the registration.config file
$clients = Get-ClientsToRegister -registrationConfig $registrationSettings
Invoke-RegisterClients -clients $clients -identityServiceUrl $identityServiceUrl -accessToken $accessToken -discoveryServiceUrl $discoveryServiceUrl

# Register shared roles and permissions
$authorization = Get-RolesAndPermissionsToRegister -registrationConfig $registrationSettings
Invoke-RegisterRolesAndPermissions -rolesAndPermissions $authorization -identityServiceUrl $identityServiceUrl -accessToken $accessToken