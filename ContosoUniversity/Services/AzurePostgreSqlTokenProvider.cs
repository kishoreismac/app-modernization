using Azure.Core;
using Azure.Identity;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace ContosoUniversity.Services
{
    public class AzurePostgreSqlTokenProvider
    {
        private readonly TokenCredential _credential;
        private readonly string[] _scopes = new[] { "https://ossrdbms-aad.database.windows.net/.default" };
        private AccessToken _currentToken;
        private readonly SemaphoreSlim _refreshLock = new SemaphoreSlim(1, 1);

        public AzurePostgreSqlTokenProvider()
        {
            _credential = new DefaultAzureCredential();
        }

        public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
        {
            // Refresh if token is expired or will expire in the next 5 minutes
            if (_currentToken.ExpiresOn <= DateTimeOffset.UtcNow.AddMinutes(5))
            {
                await _refreshLock.WaitAsync(cancellationToken);
                try
                {
                    // Double-check after acquiring lock
                    if (_currentToken.ExpiresOn <= DateTimeOffset.UtcNow.AddMinutes(5))
                    {
                        _currentToken = await _credential.GetTokenAsync(
                            new TokenRequestContext(_scopes), cancellationToken);
                    }
                }
                finally
                {
                    _refreshLock.Release();
                }
            }

            return _currentToken.Token;
        }
    }
}
