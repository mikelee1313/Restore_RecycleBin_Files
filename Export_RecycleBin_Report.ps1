<#
.SYNOPSIS
    Exports SharePoint Online recycle bin items to a CSV file for reporting and analysis.

.DESCRIPTION
    This script connects to each SharePoint Online site listed in a provided text file and retrieves all items 
    from the recycle bin in batches. Results are exported to a CSV file for easy viewing and sorting.
    It authenticates using an Azure AD application with certificate-based authentication.
    The script handles large recycle bins with potentially millions of items by processing in batches.

.PARAMETER appID
    The Azure AD application (client) ID used for authentication.

.PARAMETER thumbprint
    The thumbprint of the certificate associated with the Azure AD application.

.PARAMETER tenant
    The Azure AD tenant ID.

.PARAMETER Sites
    Path to a text file containing a list of SharePoint site URLs to process.

.OUTPUTS
    - Generates a CSV file in the specified output path containing all recycle bin items.
    - Generates a log file in the user's TEMP directory named "Export_RecycleBin_Report_<timestamp>.txt".

.NOTES
    - Requires PnP.PowerShell module.
    - Ensure the Azure AD application has appropriate permissions to read SharePoint recycle bins.
    - For very large recycle bins, consider filtering by date range or other criteria.

.EXAMPLE
    ./Export_RecycleBin_Report.ps1

    Executes the script using predefined variables and exports all recycle bin items to a CSV file.
#>

# Variables for processing
#################################################################
$appID = "1e488dc4-1977-48ef-8d4d-9856f4e04536"  
$thumbprint = "5EAD7303A5C7E27DB4245878AD554642940BA082"
$tenant = "9cfc42cb-51da-4055-87e9-b20a170b6ba3"
$Sites = Get-Content -Path "C:\temp\SiteList_DeleteItems.txt"
$csvBatchSize = 200  # Number of items to write to CSV at a time (for memory efficiency)
$outputPath = "C:\temp\RecycleBin_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

# Optional filters - set to $null to include all items
$DaysToGoBack = $null  # Set to a negative number (e.g., -30) to filter items deleted in the last X days, or $null for all items
$DeletedByName = $null  # Set to a specific user name to filter, or $null for all users
$ItemType = $null  # Set to "File" or "Folder" to filter by type, or $null for all types
################################################################

# Setup logging
$startTime = Get-Date -Format "yyyyMMdd_HHmmss"
$logFilePath = "$env:TEMP\Export_RecycleBin_Report_$startTime.txt"

function Write-Info {
    param (
        [string]$message
    )
    Add-Content -Path $logFilePath -Value "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $message"
    Write-Output "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $message"
}

# Initialize counters
$totalItemCount = 0
$isFirstBatch = $true

Write-Info "Starting Recycle Bin Report Export"
Write-Info "Output file: $outputPath"
Write-Info "Log file: $logFilePath"
Write-Info "Sites to process: $($Sites.Count)"
Write-Info "CSV export batch size: $csvBatchSize items"

# Function to export a batch of items to CSV (memory-efficient)
function Export-BatchToCsv {
    param (
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [string]$SiteUrl
    )
    
    $batch = [System.Collections.ArrayList]::new()
    
    foreach ($item in $Items) {
        $itemData = [PSCustomObject]@{
            SiteUrl        = $SiteUrl
            Id             = $item.Id
            Title          = $item.Title
            ItemType       = $item.ItemType
            ItemState      = $item.ItemState
            DirName        = $item.DirName
            LeafName       = $item.LeafName
            FullPath       = "$($item.DirName)/$($item.LeafName)"
            DeletedByName  = $item.DeletedByName
            DeletedByEmail = $item.DeletedByEmail
            DeletedDate    = $item.DeletedDate
            AuthorName     = $item.AuthorName
            AuthorEmail    = $item.AuthorEmail
            Size           = $item.Size
            SizeInMB       = [math]::Round($item.Size / 1MB, 2)
        }
        [void]$batch.Add($itemData)
    }
    
    if ($script:isFirstBatch) {
        # First batch - create new file with headers
        $batch | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        $script:isFirstBatch = $false
    }
    else {
        # Subsequent batches - append without headers
        $batch | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8 -Append
    }
    
    # Clear batch to free memory
    $batch.Clear()
    [System.GC]::Collect()
}

foreach ($SiteURL in $Sites) {
    Write-Info "=============================================="
    Write-Info "Connecting to site: $SiteURL"
    
    try {
        Connect-PnPOnline -Url $SiteURL -ClientId $appID -Tenant $tenant -Thumbprint $thumbprint
        
        $siteItemCount = 0
        
        # Process first-stage recycle bin in batches
        Write-Info "Processing first-stage recycle bin..."
        $firstStageProcessed = 0
        
        # Retrieve ALL items from recycle bin (no RowLimit to get everything)
        $recycleBinItems = Get-PnPRecycleBinItem
        
        if ($recycleBinItems) {
            # Apply filters if specified
            $filteredItems = $recycleBinItems
            
            if ($DaysToGoBack) {
                $cutoffDate = (Get-Date).AddDays($DaysToGoBack)
                $filteredItems = $filteredItems | Where-Object { $_.DeletedDate -gt $cutoffDate }
            }
            
            if ($DeletedByName) {
                $filteredItems = $filteredItems | Where-Object { $_.DeletedByName -eq $DeletedByName }
            }
            
            if ($ItemType) {
                $filteredItems = $filteredItems | Where-Object { $_.ItemType -eq $ItemType }
            }
            
            # Process in batches for memory efficiency
            $itemArray = @($filteredItems)
            $totalItems = $itemArray.Count
            Write-Info "First-stage: $totalItems items to export (after filters)"
            
            for ($i = 0; $i -lt $totalItems; $i += $csvBatchSize) {
                $endIndex = [Math]::Min($i + $csvBatchSize - 1, $totalItems - 1)
                $currentBatch = $itemArray[$i..$endIndex]
                
                Export-BatchToCsv -Items $currentBatch -SiteUrl $SiteURL
                
                $batchCount = $currentBatch.Count
                $firstStageProcessed += $batchCount
                $siteItemCount += $batchCount
                $totalItemCount += $batchCount
                
                Write-Info "Exported batch: $batchCount items (First-stage progress: $firstStageProcessed / $totalItems)"
            }
            
            # Clear to free memory
            $recycleBinItems = $null
            $filteredItems = $null
            $itemArray = $null
            [System.GC]::Collect()
        }
        
        # Process second-stage recycle bin in batches
        Write-Info "Processing second-stage recycle bin..."
        $secondStageProcessed = 0
        
        # Retrieve ALL items from second-stage recycle bin (no RowLimit to get everything)
        $secondStageItems = Get-PnPRecycleBinItem -SecondStage
        
        if ($secondStageItems) {
            # Apply filters if specified
            $filteredItems = $secondStageItems
            
            if ($DaysToGoBack) {
                $cutoffDate = (Get-Date).AddDays($DaysToGoBack)
                $filteredItems = $filteredItems | Where-Object { $_.DeletedDate -gt $cutoffDate }
            }
            
            if ($DeletedByName) {
                $filteredItems = $filteredItems | Where-Object { $_.DeletedByName -eq $DeletedByName }
            }
            
            if ($ItemType) {
                $filteredItems = $filteredItems | Where-Object { $_.ItemType -eq $ItemType }
            }
            
            # Process in batches for memory efficiency
            $itemArray = @($filteredItems)
            $totalItems = $itemArray.Count
            Write-Info "Second-stage: $totalItems items to export (after filters)"
            
            for ($i = 0; $i -lt $totalItems; $i += $csvBatchSize) {
                $endIndex = [Math]::Min($i + $csvBatchSize - 1, $totalItems - 1)
                $currentBatch = $itemArray[$i..$endIndex]
                
                Export-BatchToCsv -Items $currentBatch -SiteUrl $SiteURL
                
                $batchCount = $currentBatch.Count
                $secondStageProcessed += $batchCount
                $siteItemCount += $batchCount
                $totalItemCount += $batchCount
                
                Write-Info "Exported batch: $batchCount items (Second-stage progress: $secondStageProcessed / $totalItems)"
            }
            
            # Clear to free memory
            $secondStageItems = $null
            $filteredItems = $null
            $itemArray = $null
            [System.GC]::Collect()
        }
        
        Write-Info "Site complete: $siteItemCount items exported from $SiteURL"
        Write-Info "Running total: $totalItemCount items"
        
    }
    catch {
        Write-Info "ERROR processing site $SiteURL : $_"
    }
    finally {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }
}

Write-Info "=============================================="
Write-Info "EXPORT COMPLETE"
Write-Info "Total items exported: $totalItemCount"
Write-Info "Output file: $outputPath"
Write-Info "Log file: $logFilePath"

# Display summary
Write-Host "`n========== SUMMARY ==========" -ForegroundColor Cyan
Write-Host "Total items exported: $totalItemCount" -ForegroundColor Green
Write-Host "Output file: $outputPath" -ForegroundColor Green
Write-Host "Log file: $logFilePath" -ForegroundColor Green

if ($totalItemCount -gt 0) {
    Write-Host "`nYou can now open the CSV file in Excel for viewing and sorting." -ForegroundColor Yellow
    Write-Host "Tip: Use Excel's Filter feature to sort by DeletedDate, Size, DeletedByName, etc." -ForegroundColor Yellow
}
