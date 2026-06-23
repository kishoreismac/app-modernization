# =============================================================================
# ContosoUniversity - Azure Provision & Deploy Script
# Provisioning Tool : Azure CLI (azcli)
# IaC Type          : Bicep
# Hosting           : Azure App Service (Windows, .NET Framework 4.8)
# Database          : Azure Database for PostgreSQL Flexible Server v17
# Auth              : Managed Identity (passwordless via Service Connector)
# =============================================================================
# Usage:
#   .\deploy.ps1 -ResourceGroupName "rg-contosouniversity" `
#                -Location "eastus" `
#                -PostgresAdminPassword "YourSecureP@ssw0rd!"
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $true)]
    [SecureString]$PostgresAdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "",

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = "contosouniversity"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$WorkspaceRoot = Split-Path $ScriptDir -Parent
$InfraDir = Join-Path $WorkspaceRoot "infra"
$AppDir = Join-Path $WorkspaceRoot "ContosoUniversity"
$ProgressFile = Join-Path $WorkspaceRoot ".azure\progress.copilotmd"

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Success([string]$msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info([string]$msg)    { Write-Host "[..] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg)    { Write-Host "[!!] $msg" -ForegroundColor Red }

function Update-Progress([string]$content) {
    $dir = Split-Path $ProgressFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $ProgressFile -Value $content
}

# ---------------------------------------------------------------------------
# STEP 1: Verify / Install Azure CLI
# ---------------------------------------------------------------------------
Write-Step "Step 1: Verify Azure CLI"
try {
    $azVersion = az --version 2>&1 | Select-Object -First 1
    Write-Success "Azure CLI found: $azVersion"
} catch {
    Write-Fail "Azure CLI not found. Installing via winget..."
    winget install --id Microsoft.AzureCLI --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI installation failed. Install manually from https://aka.ms/installazurecliwindows" }
    Write-Success "Azure CLI installed."
}

# ---------------------------------------------------------------------------
# STEP 2: Azure Login & Subscription
# ---------------------------------------------------------------------------
Write-Step "Step 2: Azure Login & Subscription"
Write-Info "Logging in to Azure..."
az login
if ($LASTEXITCODE -ne 0) { throw "az login failed." }

if ($SubscriptionId -ne "") {
    Write-Info "Setting subscription to: $SubscriptionId"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription." }
}
$currentSub = (az account show --query "id" -o tsv)
Write-Success "Using subscription: $currentSub"
$subscriptionIdActual = $currentSub

# ---------------------------------------------------------------------------
# STEP 3: Install Service Connector Extension
# ---------------------------------------------------------------------------
Write-Step "Step 3: Install Service Connector Extension"
Write-Info "Installing serviceconnector-passwordless extension..."
az extension add --name serviceconnector-passwordless --upgrade --yes
if ($LASTEXITCODE -ne 0) { throw "Failed to install serviceconnector-passwordless extension." }
Write-Success "Service Connector extension installed."

# ---------------------------------------------------------------------------
# STEP 4: Create Resource Group
# ---------------------------------------------------------------------------
Write-Step "Step 4: Create Resource Group"
Write-Info "Creating resource group '$ResourceGroupName' in '$Location'..."
az group create --name $ResourceGroupName --location $Location
if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group." }
Write-Success "Resource group ready."
Update-Progress "- [x] Resource group '$ResourceGroupName' created in '$Location'"

# ---------------------------------------------------------------------------
# STEP 5: Deploy Bicep Infrastructure
# ---------------------------------------------------------------------------
Write-Step "Step 5: Deploy Bicep Infrastructure"
$pgPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PostgresAdminPassword))

Write-Info "Running az deployment group create..."
$deployOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file "$InfraDir\main.bicep" `
    --parameters "$InfraDir\main.parameters.json" `
    --parameters location=$Location environmentName=$EnvironmentName postgresAdminPassword=$pgPassword `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep deployment failed. Output:"
    Write-Host $deployOutput
    throw "Bicep deployment failed."
}

$deployJson = $deployOutput | ConvertFrom-Json
$outputs = $deployJson.properties.outputs

$AppServiceName     = $outputs.appServiceName.value
$AppServiceId       = $outputs.appServiceId.value
$AppServiceUrl      = $outputs.appServiceUrl.value
$PostgresServerName = $outputs.postgresServerName.value
$PostgresFqdn       = $outputs.postgresServerFqdn.value
$PostgresResId      = $outputs.postgresServerResourceId.value
$DbName             = $outputs.postgresDatabaseName.value
$MiClientId         = $outputs.managedIdentityClientId.value
$MiName             = $outputs.managedIdentityName.value
$ResourceGroupOut   = $outputs.resourceGroupName.value

Write-Success "Infrastructure deployed successfully."
Write-Host "  App Service  : $AppServiceUrl" -ForegroundColor Green
Write-Host "  PostgreSQL   : $PostgresFqdn" -ForegroundColor Green
Write-Host "  MI ClientId  : $MiClientId" -ForegroundColor Green
Update-Progress "- [x] Bicep infrastructure deployed"
Update-Progress "  - App Service: $AppServiceName ($AppServiceUrl)"
Update-Progress "  - PostgreSQL:  $PostgresServerName ($PostgresFqdn)"

# ---------------------------------------------------------------------------
# STEP 6: Service Connector - Passwordless PostgreSQL Connection
# Creates AAD user for the managed identity in PostgreSQL and sets env vars
# ---------------------------------------------------------------------------
Write-Step "Step 6: Service Connector - Managed Identity -> PostgreSQL"

$connectionName = "contoso-pg-connection"
Write-Info "Creating Service Connector connection '$connectionName'..."
Write-Info "  App Service ID: $AppServiceId"
Write-Info "  PostgreSQL    : $PostgresServerName / $DbName"
Write-Info "  MI Client ID  : $MiClientId"

$scOutput = az webapp connection create postgres-flexible `
    --connection $connectionName `
    --user-identity client-id=$MiClientId subs-id=$subscriptionIdActual `
    --source-id $AppServiceId `
    --target-resource-group $ResourceGroupName `
    --server $PostgresServerName `
    --database $DbName `
    --client-type dotnet `
    --yes `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Service Connector creation failed. Output:"
    Write-Host $scOutput
    throw "Service Connector failed."
}

$scJson = $scOutput | ConvertFrom-Json

# Extract the PostgreSQL userId (database role name) from the connection configuration
Write-Success "Service Connector created."
Write-Info "Connection configurations set by Service Connector:"
foreach ($cfg in $scJson.configurations) {
    Write-Host "  $($cfg.name) = $($cfg.value)" -ForegroundColor DarkCyan
}

# Service Connector sets AZURE_POSTGRESQL_CONNECTIONSTRING; extract the User Id from it
$pgConnStr = ($scJson.configurations | Where-Object { $_.name -eq "AZURE_POSTGRESQL_CONNECTIONSTRING" }).value
if ($pgConnStr) {
    $pgUserMatch = [regex]::Match($pgConnStr, "User Id=([^;]+)")
    if ($pgUserMatch.Success) {
        $pgUserId = $pgUserMatch.Groups[1].Value
        Write-Info "Detected PostgreSQL User Id: $pgUserId"

        # Update the PostgreSql:UserId app setting with the correct value
        Write-Info "Updating 'PostgreSql:UserId' App Setting to '$pgUserId'..."
        az webapp config appsettings set `
            --resource-group $ResourceGroupName `
            --name $AppServiceName `
            --settings "PostgreSql:UserId=$pgUserId" `
            --output none
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to update PostgreSql:UserId app setting." }
        else { Write-Success "PostgreSql:UserId updated to: $pgUserId" }
    }
}

# Verify the connection
Write-Info "Verifying Service Connector connection..."
$scVerify = az webapp connection show `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --connection $connectionName `
    --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Connection verification failed. Continuing..."
} else {
    Write-Success "Service Connector connection verified."
}

Update-Progress "- [x] Service Connector (managed identity) wired to PostgreSQL"

# ---------------------------------------------------------------------------
# STEP 7: Build & Package the Application
# ---------------------------------------------------------------------------
Write-Step "Step 7: Build and Package ContosoUniversity"

# Find MSBuild
$msbuildPaths = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
)
$msbuild = $msbuildPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $msbuild) {
    # Try to find via vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsInstall = & $vswhere -latest -products * -requiresAny -requires Microsoft.Component.MSBuild -property installationPath 2>$null
        if ($vsInstall) {
            $msbuild = Join-Path $vsInstall "MSBuild\Current\Bin\MSBuild.exe"
        }
    }
}

if (-not $msbuild -or -not (Test-Path $msbuild)) {
    throw "MSBuild not found. Install Visual Studio Build Tools 2022 or Visual Studio 2022 with ASP.NET workload."
}

Write-Success "MSBuild found at: $msbuild"

$publishDir = Join-Path $WorkspaceRoot ".azure\publish"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
New-Item -ItemType Directory -Path $publishDir -Force | Out-Null

Write-Info "Building and publishing ContosoUniversity..."
$slnFile = Join-Path $AppDir "ContosoUniversity.sln"
& $msbuild $slnFile `
    /p:Configuration=Release `
    /p:DeployOnBuild=true `
    /p:WebPublishMethod=FileSystem `
    /p:publishUrl=$publishDir `
    /p:DeleteExistingFiles=True `
    /p:UseWPP_CopyWebApplication=false `
    /nologo /verbosity:minimal

if ($LASTEXITCODE -ne 0) { throw "MSBuild failed. Check build errors above." }
Write-Success "Build and publish succeeded."

# Create ZIP package for deployment
$zipPath = Join-Path $WorkspaceRoot ".azure\contosouniversity-deploy.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Write-Info "Creating deployment ZIP: $zipPath"
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath -Force
Write-Success "ZIP created: $zipPath"
Update-Progress "- [x] Application built and packaged (Release)"

# ---------------------------------------------------------------------------
# STEP 8: Deploy to Azure App Service
# ---------------------------------------------------------------------------
Write-Step "Step 8: Deploy to Azure App Service"
Write-Info "Deploying ZIP to App Service '$AppServiceName'..."
az webapp deploy `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --src-path $zipPath `
    --type zip `
    --timeout 600

if ($LASTEXITCODE -ne 0) { throw "App Service ZIP deployment failed." }
Write-Success "Application deployed to Azure App Service."
Update-Progress "- [x] Application deployed to Azure App Service"

# ---------------------------------------------------------------------------
# STEP 9: Enable App Service Managed Identity in Web App config
# Ensure system-assigned identity is on (Bicep already sets it; this is a safety check)
# ---------------------------------------------------------------------------
Write-Step "Step 9: Verify App Service System-Assigned Identity"
$identityInfo = az webapp identity show `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --output json 2>&1 | ConvertFrom-Json
if ($identityInfo.principalId) {
    Write-Success "System-assigned identity principal: $($identityInfo.principalId)"
} else {
    Write-Info "Enabling system-assigned identity on '$AppServiceName'..."
    az webapp identity assign `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --output none
    Write-Success "System-assigned identity enabled."
}

# ---------------------------------------------------------------------------
# STEP 10: Validate Deployment
# ---------------------------------------------------------------------------
Write-Step "Step 10: Validate Deployment"
Write-Info "Waiting 30 seconds for the app to start..."
Start-Sleep -Seconds 30

Write-Info "Testing application endpoint: $AppServiceUrl"
try {
    $response = Invoke-WebRequest -Uri $AppServiceUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction SilentlyContinue
    Write-Success "HTTP $($response.StatusCode) - Application is responding."
} catch {
    Write-Fail "Application health check failed: $_"
    Write-Info "Fetching recent app logs..."
    az webapp log tail `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --timeout 30
}

Update-Progress "- [x] Deployment validation complete"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step "Deployment Complete!"
Write-Host ""
Write-Host "===================== SUMMARY =====================" -ForegroundColor Green
Write-Host "  Application URL  : $AppServiceUrl" -ForegroundColor Green
Write-Host "  App Service Name : $AppServiceName" -ForegroundColor Green
Write-Host "  Resource Group   : $ResourceGroupName" -ForegroundColor Green
Write-Host "  PostgreSQL Server: $PostgresFqdn" -ForegroundColor Green
Write-Host "  Managed Identity : $MiName (ClientId: $MiClientId)" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT NOTES:" -ForegroundColor Yellow
Write-Host "  1. MSMQ (used for notifications) is Windows-only and not available in" -ForegroundColor Yellow
Write-Host "     Azure App Service. Consider replacing MSMQ with Azure Service Bus" -ForegroundColor Yellow
Write-Host "     for cloud-native notifications." -ForegroundColor Yellow
Write-Host "  2. File uploads (/Uploads/TeachingMaterials/) use local disk. Consider" -ForegroundColor Yellow
Write-Host "     migrating file storage to Azure Blob Storage for persistence across" -ForegroundColor Yellow
Write-Host "     deployments and slot swaps." -ForegroundColor Yellow
Write-Host "  3. PostgreSql:UserId was auto-updated from Service Connector output." -ForegroundColor Yellow
Write-Host "     Verify the app connects to PostgreSQL successfully after first run." -ForegroundColor Yellow

Update-Progress "- [x] Deployment complete. Application live at: $AppServiceUrl"
