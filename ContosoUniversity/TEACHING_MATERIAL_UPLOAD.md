# Teaching Material Image Upload Feature

This feature allows administrators to upload images for teaching materials (textbooks) associated with courses. Images are stored in **Azure Blob Storage** for durable, cloud-native file persistence that survives application restarts and scales across multiple instances.

## Features

- **Image Upload**: Upload teaching material images when creating or editing courses
- **File Validation**: Supports JPG, JPEG, PNG, GIF, and BMP formats
- **Size Limits**: Maximum file size of 5MB per image
- **Cloud Storage**: Images are stored in an Azure Blob Storage container (`teaching-materials`)
- **Automatic Cleanup**: Blobs are automatically deleted when courses are removed or images replaced
- **Unique Filenames**: Each uploaded image gets a unique blob name to prevent conflicts

## Usage

### Creating a Course with Teaching Material Image

1. Navigate to the Courses section
2. Click "Create New" (Admin only)
3. Fill in the course details
4. In the "Teaching Material Image" section, click "Choose File"
5. Select an image file (JPG, JPEG, PNG, GIF, or BMP)
6. Click "Create" to save the course

### Editing a Course's Teaching Material Image

1. Navigate to the Courses section
2. Click "Edit" next to the course you want to modify
3. If a teaching material image already exists, it will be displayed
4. To change the image, click "Choose File" and select a new image
5. Click "Save" to update the course (the old blob is deleted automatically)

### Viewing Teaching Material Images

- **Course List**: Small thumbnails (50x50px) are displayed in the courses index
- **Course Details**: Full-size images (max 300x300px) are displayed on the course details page

## Technical Details

### File Storage

- Images are stored in the Azure Blob Storage container `teaching-materials`
- Blob names follow the pattern: `course_{CourseID}_{GUID}.{extension}`
- The full blob URL (e.g. `https://<account>.blob.core.windows.net/teaching-materials/...`) is persisted in the `TeachingMaterialImagePath` column
- Container public access is set to `Blob` level so images render directly in the browser without authentication

### Authentication

The application uses **Managed Identity** (via `DefaultAzureCredential`) to authenticate to Azure Blob Storage in production. No storage account keys or SAS tokens are stored in code or configuration.

For local development, set `BlobStorage:ConnectionString` in `Web.config` (e.g. an Azurite or Azure Storage Emulator connection string). Leave it empty in Azure — the app will fall back to `DefaultAzureCredential` using the App Service system-assigned identity.

### Configuration (Web.config appSettings)

| Key | Description |
|---|---|
| `BlobStorage:ConnectionString` | Storage connection string for local development. Leave empty in Azure. |
| `BlobStorage:AccountName` | Storage account name used in Azure (populated automatically by Bicep). |
| `BlobStorage:ContainerName` | Blob container name (default: `teaching-materials`). |

### Database Schema

- Field: `TeachingMaterialImagePath` (VARCHAR(255)) on the Course table
- Stores the full HTTPS blob URL

### Security

- File type validation prevents uploading of non-image files
- File size validation prevents uploads larger than 5MB
- Only authenticated users with appropriate roles can upload images
- Blob Storage access uses Managed Identity — no credentials in source code

### Authorization

- **Create/Upload**: Admin role required
- **Edit/Upload**: Admin or Teacher role required
- **View**: Images are publicly readable at the blob URL (no sign-in required for the image itself)
- **Delete**: Admin role required (deletes both course record and associated blob)

## Infrastructure

The `infra/main.bicep` template provisions:

1. **Storage Account** (`Standard_LRS`, `StorageV2`, HTTPS-only, TLS 1.2)
2. **Blob Container** `teaching-materials` with public blob read access
3. **Role Assignment** — grants the App Service system-assigned managed identity the `Storage Blob Data Contributor` role on the storage account

No manual post-deployment steps are needed for storage access.

## Local Development

1. Install [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) or use an Azure Storage account
2. Set `BlobStorage:ConnectionString` in `Web.config` to your connection string
3. The `teaching-materials` container will be created if it does not exist when using a connection string

## Troubleshooting

### Common Issues

1. **"File too large" error**: Ensure your image is under 5MB
2. **"Invalid file type" error**: Only JPG, JPEG, PNG, GIF, and BMP files are supported
3. **Upload fails in Azure**: Verify the App Service managed identity has the `Storage Blob Data Contributor` role on the storage account
4. **Upload fails locally**: Ensure `BlobStorage:ConnectionString` is set and Azurite/Azure Storage is running

### Configuration

The following settings in `Web.config` control file upload limits:
- `maxRequestLength="10240"` (10MB in KB)
- `maxAllowedContentLength="10485760"` (10MB in bytes)
- `executionTimeout="3600"` (1 hour timeout for large uploads)

## Future Enhancements

Potential improvements for this feature:
- Image resizing and optimization before upload
- Multiple images per course
- SAS token generation for private containers
- Lifecycle management policies to auto-expire old blobs
- CDN integration for faster global delivery
