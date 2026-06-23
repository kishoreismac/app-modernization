using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;

namespace ContosoUniversity.Services
{
    public class BlobStorageService
    {
        private static readonly Dictionary<string, string> ContentTypeMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".jpg",  "image/jpeg" },
            { ".jpeg", "image/jpeg" },
            { ".png",  "image/png" },
            { ".gif",  "image/gif" },
            { ".bmp",  "image/bmp" }
        };

        private readonly BlobContainerClient _containerClient;

        public BlobStorageService()
        {
            var connectionString = ConfigurationManager.AppSettings["BlobStorage:ConnectionString"];
            var accountName     = ConfigurationManager.AppSettings["BlobStorage:AccountName"];
            var containerName   = ConfigurationManager.AppSettings["BlobStorage:ContainerName"] ?? "teaching-materials";

            if (!string.IsNullOrEmpty(connectionString))
            {
                _containerClient = new BlobContainerClient(connectionString, containerName);
                // Ensure the container exists for local development scenarios.
                _containerClient.CreateIfNotExists(PublicAccessType.Blob);
            }
            else if (!string.IsNullOrEmpty(accountName))
            {
                var serviceUri = new Uri($"https://{accountName}.blob.core.windows.net");
                var serviceClient = new BlobServiceClient(serviceUri, new DefaultAzureCredential());
                _containerClient = serviceClient.GetBlobContainerClient(containerName);
            }
            else
            {
                throw new InvalidOperationException(
                    "Azure Blob Storage is not configured. Set 'BlobStorage:ConnectionString' or " +
                    "'BlobStorage:AccountName' in appSettings.");
            }
        }

        /// <summary>
        /// Uploads an image stream to Azure Blob Storage and returns the public blob URL.
        /// </summary>
        public string UploadImage(Stream imageStream, string blobName, string fileExtension)
        {
            string contentType;
            if (!ContentTypeMap.TryGetValue(fileExtension, out contentType))
            {
                contentType = "application/octet-stream";
            }

            var blobClient = _containerClient.GetBlobClient(blobName);
            blobClient.Upload(imageStream, new BlobHttpHeaders { ContentType = contentType });
            return blobClient.Uri.ToString();
        }

        /// <summary>
        /// Deletes a blob identified by its full URL. No-op if the URL is null/empty.
        /// Correctly handles blob names that include virtual directory separators ('/').
        /// </summary>
        public void DeleteImage(string blobUrl)
        {
            if (string.IsNullOrEmpty(blobUrl))
            {
                return;
            }

            Uri uri;
            if (!Uri.TryCreate(blobUrl, UriKind.Absolute, out uri))
            {
                return;
            }

            // AbsolutePath for a blob URL is "/{container}/{blobName}" where blobName
            // may itself contain '/' for virtual directory hierarchies.
            // Strip the leading "/{containerName}/" prefix to obtain the full blob name.
            var containerPrefix = $"/{_containerClient.Name}/";
            var absolutePath = uri.AbsolutePath;
            string blobName;

            if (absolutePath.StartsWith(containerPrefix, StringComparison.OrdinalIgnoreCase))
            {
                blobName = Uri.UnescapeDataString(absolutePath.Substring(containerPrefix.Length));
            }
            else
            {
                // Fallback: use everything after the first '/' following the host
                blobName = Uri.UnescapeDataString(absolutePath.TrimStart('/'));
            }

            _containerClient.GetBlobClient(blobName).DeleteIfExists();
        }
    }
}
