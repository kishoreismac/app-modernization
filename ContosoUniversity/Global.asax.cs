using System;
using System.Web;
using System.Web.Mvc;
using System.Web.Optimization;
using System.Web.Routing;
using Microsoft.EntityFrameworkCore;
using ContosoUniversity.Data;
using ContosoUniversity.Services;
using Microsoft.Extensions.DependencyInjection;

namespace ContosoUniversity
{
    public class MvcApplication : HttpApplication
    {
        protected void Application_Start()
        {
            AreaRegistration.RegisterAllAreas();
            FilterConfig.RegisterGlobalFilters(GlobalFilters.Filters);
            RouteConfig.RegisterRoutes(RouteTable.Routes);
            BundleConfig.RegisterBundles(BundleTable.Bundles);
            
            // Initialize database with EF Core
            InitializeDatabase();
        }

        private void InitializeDatabase()
        {
            var serverName = System.Configuration.ConfigurationManager.AppSettings["PostgreSql:ServerName"];
            var databaseName = System.Configuration.ConfigurationManager.AppSettings["PostgreSql:DatabaseName"];
            var userId = System.Configuration.ConfigurationManager.AppSettings["PostgreSql:UserId"];

            var tokenProvider = new AzurePostgreSqlTokenProvider();
            var accessToken = tokenProvider.GetAccessTokenAsync().GetAwaiter().GetResult();
            var connectionString = $"Server={serverName}.postgres.database.azure.com;Database={databaseName};User Id={userId};Password={accessToken};Ssl Mode=Require;";

            var optionsBuilder = new DbContextOptionsBuilder<SchoolContext>();
            optionsBuilder.UseNpgsql(connectionString);
            
            using (var context = new SchoolContext(optionsBuilder.Options))
            {
                DbInitializer.Initialize(context);
            }
        }
    }
}
