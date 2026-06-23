using ContosoUniversity.Services;
using Microsoft.EntityFrameworkCore;
using System.Configuration;

namespace ContosoUniversity.Data
{
    public static class SchoolContextFactory
    {
        public static SchoolContext Create()
        {
            var serverName = ConfigurationManager.AppSettings["PostgreSql:ServerName"];
            var databaseName = ConfigurationManager.AppSettings["PostgreSql:DatabaseName"];
            var userId = ConfigurationManager.AppSettings["PostgreSql:UserId"];

            var tokenProvider = new AzurePostgreSqlTokenProvider();
            var accessToken = tokenProvider.GetAccessTokenAsync().GetAwaiter().GetResult();
            var connectionString = $"Server={serverName}.postgres.database.azure.com;Database={databaseName};User Id={userId};Password={accessToken};Ssl Mode=Require;";

            var optionsBuilder = new DbContextOptionsBuilder<SchoolContext>();
            optionsBuilder.UseNpgsql(connectionString);

            return new SchoolContext(optionsBuilder.Options);
        }
    }
}
