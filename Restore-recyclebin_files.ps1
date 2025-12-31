<#
.SYNOPSIS
    Restores items from SharePoint Online recycle bins across multiple sites using batch processing.

.DESCRIPTION
    This script connects to each SharePoint Online site listed in a provided text file and restores items deleted within the 
    last two days by a specific user ("MOD Administrator"). It authenticates using an Azure AD application with certificate-based authentication. 
    Items are restored in batches of up to 200 items per API call to avoid throttling issues. 
    The script logs detailed information about each step, including successful restorations, throttling events, and errors.

.PARAMETER appID
    The Azure AD application (client) ID used for authentication.

.PARAMETER thumbprint
    The thumbprint of the certificate associated with the Azure AD application.

.PARAMETER tenant
    The Azure AD tenant ID.

.PARAMETER Sites
    Path to a text file containing a list of SharePoint site URLs to process.

.OUTPUTS
    Generates a log file in the user's TEMP directory named "Restore_RecycleBin_Item_<timestamp>.txt" containing detailed execution logs.

.NOTES
    - Requires PnP.PowerShell module.
    - Ensure the Azure AD application has appropriate permissions to access and restore items from SharePoint recycle bins.
    - Handles throttling responses (HTTP 429) by respecting the "Retry-After" header.

.EXAMPLE
    ./Restore-recyclebin_files.ps1

    Executes the script using predefined variables and restores recently deleted items from the recycle bins of sites listed in "C:\temp\SiteList_DeleteItems.txt".
#>

# Variables for processing
#################################################################
$appID = "1e488dc4-1977-48ef-8d4d-9856f4e04536"  
$thumbprint = "5EAD7303A5C7E27DB4245878AD554642940BA082"
$tenant = "9cfc42cb-51da-4055-87e9-b20a170b6ba3"
$Sites = Get-content -Path "C:\\temp\\SiteList_DeleteItems.txt"
$batchSize = 50  # Number of items to restore per API call
$DaysToGoBack = -2  # Number of days to look back for deleted items
$DeletedByName = "MOD Administrator"  # Filter by user who deleted the items
################################################################


# Setup logging
$startime = Get-Date -Format "yyyyMMdd_HHmmss"
$logFilePath = "$env:TEMP\\Restore_RecycleBin_Item_$startime.txt"

function Write-Info {
    param (
        [string]$message
    )
    Add-Content -Path $logFilePath -Value "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $message"
    Write-Output "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $message"
}

foreach ($SiteURL in $Sites) {
    Write-Info "Connecting to site: $SiteURL"
    Connect-PnPOnline -Url $SiteURL -ClientId $appID -Tenant $tenant -Thumbprint $thumbprint
    $restoreSet = Get-PnPRecycleBinItem | Where-Object { $_.DeletedDate -gt (Get-Date).AddDays($DaysToGoBack) -and $_.DeletedByName -eq $DeletedByName }
    $restoreSetCount = $restoreSet.Count

    # Batch restore using configured batch size
    $apiCall = $SiteURL + "/_api/site/RecycleBin/RestoreByIds"
    $start = 0
    $leftToProcess = $restoreSetCount - $start

    while ($leftToProcess -gt 0) {
        if ($leftToProcess -lt $batchSize) {
            $numToProcess = $leftToProcess
        }
        else {
            $numToProcess = $batchSize
        }

        Write-Info "Building statement to restore the following $numToProcess files"
        $body = "{""ids"":["

        for ($i = 0; $i -lt $numToProcess; $i++) {
            $cur = $start + $i
            $curItem = $restoreSet[$cur]
            $Id = $curItem.Id
            Write-Info "Adding $($curItem.ItemType): $($curItem.DirName)//$($curItem.LeafName)"
            $body += "`"$Id`""
            if ($i -ne $numToProcess - 1) {
                $body += ","
            }
        }

        $body += "]}"
        Write-Info "Performing API Call to Restore items from RecycleBin..."

        try {
            $response = Invoke-PnPSPRestMethod -Method Post -Url $apiCall -Content $body
            if ($response.StatusCode -eq 429) {
                # Throttling response
                $retryAfter = [int]$response.Headers["Retry-After"]
                Write-Info "Throttled. Retrying after $retryAfter seconds."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            Write-Info "API Call successful. Status Code: $($response.StatusCode)"
        }
        catch {
            Write-Info "Unable to Restore: $_"
        }

        # Increment start and update leftToProcess
        $start += $numToProcess
        $leftToProcess = $restoreSetCount - $start

        # Update progress
        Write-Info "$start items processed, $leftToProcess items left to process."
    }
}
