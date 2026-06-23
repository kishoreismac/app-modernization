targetScope = 'resourceGroup'

@description('Environment name used to generate unique resource name tokens.')
param environmentName string = 'contosouniversity'

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('PostgreSQL flexible server administrator login name.')
param postgresAdminLogin string = 'pgadmin'

@secure()
@description('PostgreSQL flexible server administrator password.')
param postgresAdminPassword string

// ---------------------------------------------------------------------------
// Naming
// Resource token: uniqueString scoped to subscription + resource group + location + env
// Convention: az{prefix<=3chars}{token}
// ---------------------------------------------------------------------------
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location, environmentName)

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity
// Used by Service Connector to grant the web app passwordless access to PostgreSQL
// ---------------------------------------------------------------------------
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'azumi${resourceToken}'
  location: location
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// Central log sink for App Service diagnostics and Application Insights
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'azlw${resourceToken}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Application Insights
// APM and diagnostics connected to Log Analytics Workspace
// ---------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'azai${resourceToken}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    RetentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// App Service Plan (Windows)
// properties.reserved = false for Windows; true for Linux
// ---------------------------------------------------------------------------
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'azasp${resourceToken}'
  location: location
  sku: {
    name: 'B2'
    tier: 'Basic'
    size: 'B2'
    capacity: 1
  }
  kind: 'app'
  properties: {
    reserved: false
  }
}

// ---------------------------------------------------------------------------
// Azure Database for PostgreSQL Flexible Server
// Version 17, AAD + password auth, firewall allows Azure services
// ---------------------------------------------------------------------------
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'azpg${resourceToken}'
  location: location
  sku: {
    name: 'Standard_B2ms'
    tier: 'Burstable'
  }
  properties: {
    version: '17'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
    }
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// PostgreSQL database (must NOT be named 'postgres')
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgresServer
  name: 'ContosoUniversity'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Firewall rule to allow all Azure services (startIp = endIp = 0.0.0.0)
resource postgresFirewallAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------
// App Service (Windows, .NET Framework 4.8)
// System-assigned + user-assigned managed identity attached
// HTTPS-only, TLS 1.2 minimum, CORS enabled
// ---------------------------------------------------------------------------
resource appService 'Microsoft.Web/sites@2023-12-01' = {
  name: 'azapp${resourceToken}'
  location: location
  kind: 'app'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v4.8'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
        supportCredentials: false
      }
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'Recommended'
        }
        {
          name: 'PostgreSql:ServerName'
          value: postgresServer.name
        }
        {
          name: 'PostgreSql:DatabaseName'
          value: 'ContosoUniversity'
        }
        {
          name: 'PostgreSql:UserId'
          value: 'PLACEHOLDER_UPDATE_AFTER_SERVICE_CONNECTOR'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: managedIdentity.properties.clientId
        }
        {
          name: 'NotificationQueuePath'
          value: '.\\Private$\\ContosoUniversityNotifications'
        }
        {
          name: 'BlobStorage:AccountName'
          value: storageAccount.name
        }
        {
          name: 'BlobStorage:ContainerName'
          value: 'teaching-materials'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Diagnostic settings for App Service → Log Analytics Workspace
// ---------------------------------------------------------------------------
resource appServiceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'appservice-diagnostics'
  scope: appService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Azure Storage Account
// Stores teaching material images in a blob container.
// Public blob read access is enabled so images can be rendered directly in browser.
// The App Service's system-assigned managed identity is granted
// Storage Blob Data Contributor to upload and delete blobs.
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'azst${resourceToken}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource teachingMaterialsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'teaching-materials'
  properties: {
    publicAccess: 'Blob'
  }
}

// Storage Blob Data Contributor role for the App Service system-assigned managed identity
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
resource blobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, appService.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: appService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output appServiceId string = appService.id
output postgresServerName string = postgresServer.name
output postgresServerFqdn string = postgresServer.properties.fullyQualifiedDomainName
output postgresServerResourceId string = postgresServer.id
output postgresDatabaseName string = postgresDatabase.name
output managedIdentityClientId string = managedIdentity.properties.clientId
output managedIdentityName string = managedIdentity.name
output managedIdentityId string = managedIdentity.id
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output resourceGroupName string = resourceGroup().name
output storageAccountName string = storageAccount.name
output storageAccountBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output teachingMaterialsContainerName string = teachingMaterialsContainer.name
