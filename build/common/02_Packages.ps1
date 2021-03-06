<# 
    .SYNOPSIS
        Downloads packages from blob storage and applies to the local machine.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $False)]
    [System.String] $Log = "$env:SystemRoot\Logs\PackerImagePrep.log",

    [Parameter(Mandatory = $False)]
    [System.String] $Target = "$env:SystemDrive\Apps"
)

#region Functions
Function Get-AzureBlobItem {
    <#
        .SYNOPSIS
            Returns an array of items and properties from an Azure blog storage URL.

        .DESCRIPTION
            Queries an Azure blog storage URL and returns an array with properties of files in a Container.
            Requires Public access level of anonymous read access to the blob storage container.
            Works with PowerShell Core.
            
        .NOTES
            Author: Aaron Parker
            Twitter: @stealthpuppy

        .PARAMETER Url
            The Azure blob storage container URL. The container must be enabled for anonymous read access.
            The URL must include the List Container request URI. See https://docs.microsoft.com/en-us/rest/api/storageservices/list-containers2 for more information.
        
        .EXAMPLE
            Get-AzureBlobItems -Uri "https://aaronparker.blob.core.windows.net/folder/?comp=list"

            Description:
            Returns the list of files from the supplied URL, with Name, URL, Size and Last Modifed properties for each item.
    #>
    [CmdletBinding(SupportsShouldProcess = $False)]
    [OutputType([System.Management.Automation.PSObject])]
    Param (
        [Parameter(ValueFromPipeline = $True, Mandatory = $True, HelpMessage = "Azure blob storage URL with List Containers request URI '?comp=list'.")]
        [ValidatePattern("^(http|https)://")]
        [System.String] $Uri
    )

    # Get response from Azure blog storage; Convert contents into usable XML, removing extraneous leading characters
    try {
        $iwrParams = @{
            Uri             = $Uri
            UseBasicParsing = $True
            ContentType     = "application/xml"
            ErrorAction     = "Stop"
        }
        $list = Invoke-WebRequest @iwrParams
    }
    catch [System.Net.WebException] {
        Write-Warning -Message ([string]::Format("Error : {0}", $_.Exception.Message))
    }
    catch [System.Exception] {
        Write-Warning -Message "$($MyInvocation.MyCommand): failed to download: $Uri."
        Throw $_.Exception.Message
    }
    If ($Null -ne $list) {
        [System.Xml.XmlDocument] $xml = $list.Content.Substring($list.Content.IndexOf("<?xml", 0))

        # Build an object with file properties to return on the pipeline
        $fileList = New-Object -TypeName System.Collections.ArrayList
        ForEach ($node in (Select-Xml -XPath "//Blobs/Blob" -Xml $xml).Node) {
            $PSObject = [PSCustomObject] @{
                Name         = ($node | Select-Object -ExpandProperty Name)
                Url          = ($node | Select-Object -ExpandProperty Url)
                Size         = ($node | Select-Object -ExpandProperty Size)
                LastModified = ($node | Select-Object -ExpandProperty LastModified)
            }
            $fileList.Add($PSObject) > $Null
        }
        If ($Null -ne $fileList) {
            Write-Output -InputObject $fileList
        }
    }
}

Function Install-LanguageCapability ($Locale) {
    Switch ($Locale) {
        "en-US" {
            # United States
            $Language = "en-US"
        }
        "en-GB" {
            # Great Britain
            $Language = "en-GB"
        }
        "en-AU" {
            # Australia
            $Language = "en-AU", "en-GB"
        }
        Default {
            # Australia
            $Language = "en-AU", "en-GB"
        }
    }

    # Install Windows capability packages using Windows Update
    ForEach ($lang in $Language) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Adding packages for [$lang]."
        $Capabilities = Get-WindowsCapability -Online | Where-Object { $_.Name -like "Language*$lang*" }
        ForEach ($Capability in $Capabilities) {
            try {
                Add-WindowsCapability -Online -Name $Capability.Name -LogLevel 2
            }
            catch {
                Throw "Failed to add capability: $($Capability.Name)."
            }
        }
    }
}

Function Install-Packages ($Path, $PackagesUrl) {
    # Get the list of items from blob storage
    try {
        $Items = Get-AzureBlobItem -Uri "$($PackagesUrl)?comp=list" | Where-Object { $_.Name -match "zip?" }
    }
    catch {
        Write-Host "================ Failed to retrieve items from: [$PackagesUrl]."
        Throw "Failed to retrieve items from: [$PackagesUrl]."
    }

    ForEach ($item in $Items) {
        $AppName = $item.Name -replace ".zip"
        $AppPath = Join-Path -Path $Path -ChildPath $AppName
        If (!(Test-Path $AppPath)) { New-Item -Path $AppPath -ItemType "Directory" -Force -ErrorAction "SilentlyContinue" > $Null }

        Write-Host "================ Downloading item: [$($item.Url)]."
        $OutFile = Join-Path -Path $Path -ChildPath (Split-Path -Path $item.Url -Leaf)
        try {
            Invoke-WebRequest -Uri $item.Url -OutFile $OutFile -UseBasicParsing
        }
        catch {
            Write-Host "================ Failed to download: $($item.Url)."
            Break
        }
        Expand-Archive -Path $OutFile -DestinationPath $AppPath -Force -Verbose
        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue

        Write-Host "================ Installing item: $($AppName)."
        Push-Location $AppPath
        Get-ChildItem -Path $AppPath -Recurse | Unblock-File
        . .\Install.ps1
        Pop-Location
    }
}
#endregion


#region Script logic
# Set $VerbosePreference so full details are sent to the log; Make Invoke-WebRequest faster
$VerbosePreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Set TLS to 1.2; Create target folder
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -Path $Target -ItemType "Directory" -Force -ErrorAction "SilentlyContinue" > $Null

# Run tasks
Install-Packages -Path $Target -PackagesUrl $Env:PackagesUrl
Write-Host "================ Complete: Packages."
