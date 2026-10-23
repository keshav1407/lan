# ==============================================================================
# Host/Publisher.ps1
# LAN Dynamic Wallpaper - Automated Validation & Atomic Publication Engine
# Pure Windows PowerShell 5.1+ / .NET interop - Zero external dependencies
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WallpapersDir,

    [Parameter(Mandatory = $false)]
    [string]$PublishedDir,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif ($null -ne $MyInvocation -and $null -ne $MyInvocation.MyCommand -and ($MyInvocation.MyCommand.PSObject.Properties['Path'])) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}
if (-not (Test-Path variable:IsImportedModule) -or -not $IsImportedModule) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDir "HostConfig.json"
    }
}

# Global watcher state
$script:Watcher = $null
$script:LastSyncTime = [DateTime]::MinValue
$script:DebounceTimer = $null
$script:SyncLock = New-Object System.Object

# Preload WPF and System.Drawing assemblies for image/video format transcoding
try {
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
} catch {}

function Get-PublisherConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $Path = $Path.Trim().Trim('"').Trim("'")
    }

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            return ($raw | ConvertFrom-Json)
        }
        catch {
            Write-Warning "Failed to parse configuration at $Path. Using built-in defaults: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Server = [PSCustomObject]@{
            Port = 8765
        }
        Security = [PSCustomObject]@{
            MaxImageSizeBytes = 104857600
            AllowedExtensions = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp", ".heic", ".heif", ".tiff", ".tif", ".ico", ".mp4", ".mov", ".wmv", ".avi", ".mkv")
        }
        Slideshow = [PSCustomObject]@{
            DefaultIntervalSeconds = 5
        }
        Paths = [PSCustomObject]@{
            WallpapersDir = "../Wallpapers"
            PublishedDir = "../Published"
            LogsDir = "../Logs"
        }
    }
}

function Test-FileCopyComplete {
    <#
    .SYNOPSIS
    Verifies that a file is completely written and no longer locked by copying processes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [int]$MaxRetries = 5,
        [int]$DelayMilliseconds = 300
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            $fileStream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            if ($null -ne $fileStream) {
                $fileStream.Close()
                $fileStream.Dispose()
                return $true
            }
        }
        catch [System.IO.IOException] {
            # File is actively locked by an in-progress copy or download operation
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
        catch {
            Write-Verbose "Error testing file lock on $FilePath : $($_.Exception.Message)"
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $false
}

function Test-ValidImageBinary {
    <#
    .SYNOPSIS
    Validates file headers and binary magic numbers (JPEG, PNG, BMP) to reject spoofed files.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [long]$MaxSizeBytes = 26214400
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return @{ IsValid = $false; Reason = "File does not exist" }
    }

    $item = Get-Item -LiteralPath $FilePath
    if ($item.Length -le 0) {
        return @{ IsValid = $false; Reason = "File is zero bytes" }
    }

    if ($item.Length -gt $MaxSizeBytes) {
        return @{ IsValid = $false; Reason = "File exceeds maximum size ($($item.Length) > $MaxSizeBytes)" }
    }

    $ext = $item.Extension.ToLowerInvariant()
    $headerBytes = New-Object byte[] 16

    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        $readCount = $fs.Read($headerBytes, 0, 16)
        $fs.Close()
        $fs.Dispose()

        if ($readCount -lt 4) {
            return @{ IsValid = $false; Reason = "File header too short" }
        }

        switch ($ext) {
            { $_ -in @(".jpg", ".jpeg", ".jfif", ".pjpeg") } {
                # JPEG SOI marker: FF D8
                if ($headerBytes[0] -eq 0xFF -and $headerBytes[1] -eq 0xD8) {
                    return @{ IsValid = $true; Reason = "Valid JPEG" }
                }
                return @{ IsValid = $false; Reason = "Invalid JPEG header bytes" }
            }
            ".png" {
                # PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
                if ($readCount -ge 8 -and
                    $headerBytes[0] -eq 0x89 -and $headerBytes[1] -eq 0x50 -and
                    $headerBytes[2] -eq 0x4E -and $headerBytes[3] -eq 0x47 -and
                    $headerBytes[4] -eq 0x0D -and $headerBytes[5] -eq 0x0A -and
                    $headerBytes[6] -eq 0x1A -and $headerBytes[7] -eq 0x0A) {
                    return @{ IsValid = $true; Reason = "Valid PNG" }
                }
                return @{ IsValid = $false; Reason = "Invalid PNG header bytes" }
            }
            ".bmp" {
                # BMP magic bytes: 42 4D ('BM')
                if ($headerBytes[0] -eq 0x42 -and $headerBytes[1] -eq 0x4D) {
                    return @{ IsValid = $true; Reason = "Valid BMP" }
                }
                return @{ IsValid = $false; Reason = "Invalid BMP header bytes" }
            }
            ".gif" {
                # GIF magic bytes: 47 49 46 38 ('GIF8')
                if ($headerBytes[0] -eq 0x47 -and $headerBytes[1] -eq 0x49 -and $headerBytes[2] -eq 0x46 -and $headerBytes[3] -eq 0x38) {
                    return @{ IsValid = $true; Reason = "Valid GIF" }
                }
                return @{ IsValid = $false; Reason = "Invalid GIF header bytes" }
            }
            { $_ -in @(".heic", ".heif") } {
                return @{ IsValid = $true; Reason = "Valid HEIC container" }
            }
            ".webp" {
                if ($headerBytes[0] -eq 0x52 -and $headerBytes[1] -eq 0x49 -and $headerBytes[2] -eq 0x46 -and $headerBytes[3] -eq 0x46) {
                    return @{ IsValid = $true; Reason = "Valid WebP" }
                }
                return @{ IsValid = $false; Reason = "Invalid WebP header bytes" }
            }
            { $_ -in @(".tiff", ".tif") } {
                if (($headerBytes[0] -eq 0x49 -and $headerBytes[1] -eq 0x49 -and $headerBytes[2] -eq 0x2A) -or
                    ($headerBytes[0] -eq 0x4D -and $headerBytes[1] -eq 0x4D -and $headerBytes[3] -eq 0x2A)) {
                    return @{ IsValid = $true; Reason = "Valid TIFF" }
                }
                return @{ IsValid = $false; Reason = "Invalid TIFF header bytes" }
            }
            ".ico" {
                if ($headerBytes[0] -eq 0x00 -and $headerBytes[1] -eq 0x00 -and $headerBytes[2] -eq 0x01 -and $headerBytes[3] -eq 0x00) {
                    return @{ IsValid = $true; Reason = "Valid ICO" }
                }
                return @{ IsValid = $false; Reason = "Invalid ICO header bytes" }
            }
            { $_ -in @(".mp4", ".mov", ".wmv", ".avi", ".mkv") } {
                return @{ IsValid = $true; Reason = "Valid Video Media Container" }
            }
            default {
                return @{ IsValid = $false; Reason = "Unsupported extension: $ext" }
            }
        }
    }
    catch {
        return @{ IsValid = $false; Reason = "Header read exception: $($_.Exception.Message)" }
    }
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
    Computes lowercase hexadecimal SHA-256 hash for arbitrary files.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        $hashBytes = $sha256.ComputeHash($stream)
        $stream.Close()
        $stream.Dispose()
        $builder = New-Object System.Text.StringBuilder
        foreach ($b in $hashBytes) {
            [void]$builder.Append($b.ToString("x2"))
        }
        return $builder.ToString()
    }
    finally {
        $sha256.Dispose()
    }
}

function Convert-ToStandardWallpaperImage {
    <#
    .SYNOPSIS
    Transcodes diverse image formats (HEIC, WebP, GIF, TIFF, ICO) or extracts video snapshots (MP4, MOV, WMV, AVI)
    into standard high-definition JPEG wallpaper assets ready for Windows desktop display.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

    $ext = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $outJpg = Join-Path $TargetDir ($baseName + ".jpg")

    if ($ext -in @(".jpg", ".jpeg", ".png", ".bmp")) {
        return $SourcePath
    }

    # 1. Try WPF BitmapDecoder (HEIC, WebP, GIF, TIFF, ICO)
    try {
        $uri = New-Object System.Uri($SourcePath)
        $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($uri, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        if ($dec.Frames.Count -gt 0) {
            $frame = $dec.Frames[0]
            $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
            $enc.QualityLevel = 95
            $enc.Frames.Add($frame)
            $fs = [System.IO.File]::Create($outJpg)
            $enc.Save($fs)
            $fs.Close()
            $fs.Dispose()
            Write-Verbose "Converted $ext asset to JPEG: $baseName.jpg"
            return $outJpg
        }
    } catch {}

    # 2. Try System.Drawing fallback
    try {
        $img = [System.Drawing.Image]::FromFile($SourcePath)
        $img.Save($outJpg, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $img.Dispose()
        return $outJpg
    } catch {}

    # 3. Video snapshot extraction fallback
    if ($ext -in @(".mp4", ".mov", ".wmv", ".avi", ".mkv")) {
        try {
            $player = New-Object System.Windows.Media.MediaPlayer
            $player.ScrubbingEnabled = $true
            $player.Open((New-Object System.Uri($SourcePath)))
            Start-Sleep -Milliseconds 300
            $player.Position = [TimeSpan]::FromSeconds(1)

            $width = if ($player.NaturalVideoWidth -gt 0) { $player.NaturalVideoWidth } else { 1920 }
            $height = if ($player.NaturalVideoHeight -gt 0) { $player.NaturalVideoHeight } else { 1080 }

            $dv = New-Object System.Windows.Media.DrawingVisual
            $dc = $dv.RenderOpen()
            $dc.DrawVideo($player, (New-Object System.Windows.Rect(0, 0, $width, $height)))
            $dc.Close()

            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($dv)

            $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
            $enc.QualityLevel = 95
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))

            $fs = [System.IO.File]::Create($outJpg)
            $enc.Save($fs)
            $fs.Close()
            $fs.Dispose()
            $player.Close()
            return $outJpg
        } catch {}
    }

    return $null
}

function Sync-WallpaperCollection {
    <#
    .SYNOPSIS
    Scans the Wallpapers directory, validates images, calculates SHA-256 hashes,
    and updates the Published directory atomically with a versioned manifest.
    #>
    [CmdletBinding()]
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [long]$MaxSizeBytes = 104857600,
        [string[]]$AllowedExts = @(".jpg", ".jpeg", ".jfif", ".pjpeg", ".png", ".bmp", ".gif", ".webp", ".heic", ".heif", ".tiff", ".tif", ".ico", ".mp4", ".mov", ".wmv", ".avi", ".mkv"),
        [int]$SlideshowInterval = 5
    )

    [System.Threading.Monitor]::Enter($script:SyncLock)
    try {
        # Resolve directories
        $baseDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { $scriptDir }
        if ([string]::IsNullOrWhiteSpace($SourceDir)) {
            $SourceDir = [System.IO.Path]::GetFullPath((Join-Path $baseDir "../Wallpapers"))
        }
        if ([string]::IsNullOrWhiteSpace($TargetDir)) {
            $TargetDir = [System.IO.Path]::GetFullPath((Join-Path $baseDir "../Published"))
        }

        if (-not (Test-Path -LiteralPath $SourceDir)) {
            New-Item -ItemType Directory -Path $SourceDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }

        $manifestPath = Join-Path $TargetDir "manifest.json"
        $existingManifest = $null
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                Write-Verbose "Could not read existing manifest: $($_.Exception.Message)"
            }
        }

        # Retrieve source files deterministically (excluding metadata and temp files)
        $allFiles = Get-ChildItem -LiteralPath $SourceDir -File |
            Where-Object { $_.Name -ne "manifest.json" -and -not $_.Name.EndsWith(".pubtmp") -and -not $_.Name.EndsWith(".tmp") } |
            Sort-Object -Property Name
        $validImages = New-Object System.Collections.Generic.List[PSCustomObject]
        $totalBytes = 0

        foreach ($file in $allFiles) {
            $ext = $file.Extension.ToLowerInvariant()
            if ($ext -notin $AllowedExts) {
                Write-Host " [Notice] Skipping unsupported file format '$($file.Name)' ($ext). Supported: $($AllowedExts -join ', ')" -ForegroundColor DarkGray
                continue
            }

            # Wait for any active file copy
            if (-not (Test-FileCopyComplete -FilePath $file.FullName)) {
                Write-Warning "File copy incomplete or locked: $($file.Name). Retaining existing collection."
                return $existingManifest
            }

            # Binary header check
            $validation = Test-ValidImageBinary -FilePath $file.FullName -MaxSizeBytes $MaxSizeBytes
            if (-not $validation.IsValid) {
                Write-Warning "Image validation failed for '$($file.Name)': $($validation.Reason)"
                continue
            }

            $effectiveFile = $file
            $effectiveName = $file.Name
            $effectiveExt = $ext
            $effectiveSourcePath = $file.FullName

            # Auto-transcode non-standard formats (HEIC, WebP, GIF, TIFF, Videos) to high-def JPEG
            if ($ext -notin @(".jpg", ".jpeg", ".png", ".bmp")) {
                $converted = Convert-ToStandardWallpaperImage -SourcePath $file.FullName -TargetDir $TargetDir
                if ($converted -and (Test-Path -LiteralPath $converted)) {
                    $effectiveFile = Get-Item -LiteralPath $converted
                    $effectiveName = $effectiveFile.Name
                    $effectiveExt = $effectiveFile.Extension.ToLowerInvariant()
                    $effectiveSourcePath = $converted
                    Write-Host " [Auto-Convert] Processed '$($file.Name)' ($ext) -> '$effectiveName'" -ForegroundColor Green
                } else {
                    Write-Warning "Could not convert asset '$($file.Name)' ($ext) to standard wallpaper."
                    continue
                }
            }

            # Compute SHA-256 hash
            $hash = Get-FileSha256 -FilePath $effectiveSourcePath

            $imgObj = [PSCustomObject]@{
                name         = $effectiveName
                hash         = $hash
                size         = $effectiveFile.Length
                extension    = $effectiveExt
                modified     = $effectiveFile.LastWriteTimeUtc.ToString("o")
                downloadUrl  = "/api/v1/wallpaper/$([System.Uri]::EscapeDataString($effectiveName))"
                sourcePath   = $effectiveSourcePath
            }
            $validImages.Add($imgObj)
            $totalBytes += $effectiveFile.Length
        }

        # Check if collection has changed compared to existing manifest
        $hasChanged = $false
        if ($null -eq $existingManifest -or $null -eq $existingManifest.images) {
            $hasChanged = $true
        }
        else {
            if ($existingManifest.images.Count -ne $validImages.Count) {
                $hasChanged = $true
            }
            else {
                for ($idx = 0; $idx -lt $validImages.Count; $idx++) {
                    $curr = $validImages[$idx]
                    $prev = $existingManifest.images[$idx]
                    if ($curr.name -ne $prev.name -or $curr.hash -ne $prev.hash) {
                        $hasChanged = $true
                        break
                    }
                }
            }
        }

        if (-not $hasChanged) {
            Write-Verbose "Collection unchanged. Manifest remains at version $($existingManifest.collectionVersion)."
            return $existingManifest
        }

        # Atomic publication: Copy valid images to target directory
        $activePublishedNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($img in $validImages) {
            $destPath = Join-Path $TargetDir $img.name
            [void]$activePublishedNames.Add($img.name)

            $needsCopy = $true
            if (Test-Path -LiteralPath $destPath) {
                $existingDestHash = Get-FileSha256 -FilePath $destPath
                if ($existingDestHash -eq $img.hash) {
                    $needsCopy = $false
                }
            }

            if ($needsCopy) {
                if ($img.sourcePath -ne $destPath) {
                    $tempDest = Join-Path $TargetDir "$($img.name).pubtmp"
                    Copy-Item -LiteralPath $img.sourcePath -Destination $tempDest -Force
                    Move-Item -LiteralPath $tempDest -Destination $destPath -Force
                    Write-Verbose "Published updated asset: $($img.name) (Hash: $($img.hash))"
                }
            }
        }

        # Prune obsolete images in Published directory (protecting original source files in single-folder mode)
        $isSingleFolder = ($SourceDir.TrimEnd('\').TrimEnd('/') -eq $TargetDir.TrimEnd('\').TrimEnd('/'))
        $sourceFileNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($af in $allFiles) { [void]$sourceFileNames.Add($af.Name) }

        $publishedFiles = Get-ChildItem -LiteralPath $TargetDir -File
        foreach ($pf in $publishedFiles) {
            if ($pf.Name -eq "manifest.json" -or $pf.Name.EndsWith(".pubtmp") -or $pf.Name.EndsWith(".tmp")) {
                continue
            }
            if ($isSingleFolder -and $sourceFileNames.Contains($pf.Name)) {
                # Never prune original user files in single-folder mode
                continue
            }
            if (-not $activePublishedNames.Contains($pf.Name)) {
                Remove-Item -LiteralPath $pf.FullName -Force -ErrorAction SilentlyContinue
                Write-Verbose "Pruned obsolete published image: $($pf.Name)"
            }
        }

        # Generate atomic versioned manifest
        $timestamp = [DateTime]::UtcNow
        $versionId = "v{0}_{1}" -f $timestamp.ToString("yyyyMMddHHmmss"), ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))

        $manifestData = [PSCustomObject]@{
            protocolVersion   = "1.0"
            collectionVersion = $versionId
            timestamp         = $timestamp.ToString("o")
            slideshowInterval = $SlideshowInterval
            totalImages       = $validImages.Count
            totalBytes        = $totalBytes
            images            = @($validImages | ForEach-Object {
                [PSCustomObject]@{
                    name        = $_.name
                    hash        = $_.hash
                    size        = $_.size
                    extension   = $_.extension
                    modified    = $_.modified
                    downloadUrl = $_.downloadUrl
                }
            })
        }

        $jsonPayload = $manifestData | ConvertTo-Json -Depth 5
        $tmpManifest = Join-Path $TargetDir "manifest.json.tmp"
        [System.IO.File]::WriteAllText($tmpManifest, $jsonPayload, [System.Text.Encoding]::UTF8)

        # Atomic replacement of manifest
        Move-Item -LiteralPath $tmpManifest -Destination $manifestPath -Force

        $script:LastSyncTime = [DateTime]::UtcNow
        Write-Verbose "Manifest successfully published. Version: $versionId | Images: $($validImages.Count) | Bytes: $totalBytes"
        return $manifestData
    }
    catch {
        Write-Error "Failed to synchronize wallpaper collection: $($_.Exception.Message)"
        return $null
    }
    finally {
        [System.Threading.Monitor]::Exit($script:SyncLock)
    }
}

function Start-WallpaperWatcher {
    <#
    .SYNOPSIS
    Starts a background FileSystemWatcher on the Wallpapers directory with debounced event handling.
    #>
    [CmdletBinding()]
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [long]$MaxSizeBytes = 26214400,
        [string[]]$AllowedExts = @(".jpg", ".jpeg", ".png", ".bmp"),
        [int]$SlideshowInterval = 60,
        [int]$DebounceMilliseconds = 1500
    )

    if ([string]::IsNullOrWhiteSpace($SourceDir)) {
        $SourceDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../Wallpapers"))
    }
    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        $TargetDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../Published"))
    }

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        New-Item -ItemType Directory -Path $SourceDir -Force | Out-Null
    }

    Stop-WallpaperWatcher

    $fsw = New-Object System.IO.FileSystemWatcher
    $fsw.Path = $SourceDir
    $fsw.IncludeSubdirectories = $false
    $fsw.EnableRaisingEvents = $true
    $fsw.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'

    $action = {
        param($source, $eventArgs)
        # Prevent self-trigger loop in single-folder mode on manifest updates or temporary files
        if ($eventArgs.Name -eq "manifest.json" -or $eventArgs.Name.EndsWith(".pubtmp") -or $eventArgs.Name.EndsWith(".tmp")) {
            return
        }
        $now = [DateTime]::UtcNow
        # Simple debounce threshold
        if (($now - $script:LastSyncTime).TotalMilliseconds -gt 1000) {
            Start-Sleep -Milliseconds 500
            Sync-WallpaperCollection -SourceDir $using:SourceDir -TargetDir $using:TargetDir `
                -MaxSizeBytes $using:MaxSizeBytes -AllowedExts $using:AllowedExts -SlideshowInterval $using:SlideshowInterval | Out-Null
        }
    }

    Register-ObjectEvent $fsw -EventName Created -SourceIdentifier "FSW_Wallpaper_Created" -Action $action | Out-Null
    Register-ObjectEvent $fsw -EventName Changed -SourceIdentifier "FSW_Wallpaper_Changed" -Action $action | Out-Null
    Register-ObjectEvent $fsw -EventName Deleted -SourceIdentifier "FSW_Wallpaper_Deleted" -Action $action | Out-Null
    Register-ObjectEvent $fsw -EventName Renamed -SourceIdentifier "FSW_Wallpaper_Renamed" -Action $action | Out-Null

    $script:Watcher = $fsw
    Write-Verbose "FileSystemWatcher successfully attached to $SourceDir"
}

function Stop-WallpaperWatcher {
    <#
    .SYNOPSIS
    Stops and unregisters the background FileSystemWatcher.
    #>
    $events = @("FSW_Wallpaper_Created", "FSW_Wallpaper_Changed", "FSW_Wallpaper_Deleted", "FSW_Wallpaper_Renamed")
    foreach ($evt in $events) {
        $sub = Get-EventSubscriber -SourceIdentifier $evt -ErrorAction SilentlyContinue
        if ($null -ne $sub) {
            Unregister-Event -SourceIdentifier $evt -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -ne $script:Watcher) {
        $script:Watcher.EnableRaisingEvents = $false
        $script:Watcher.Dispose()
        $script:Watcher = $null
        Write-Verbose "FileSystemWatcher detached and disposed."
    }
}

# If executed directly as a script (not dot-sourced)
if ($null -ne $PSCommandPath -and $null -ne $MyInvocation.MyCommand -and ($MyInvocation.MyCommand.Path -eq $PSCommandPath) -and ($MyInvocation.InvocationName -ne '.') -and -not (Test-Path variable:IsImportedModule)) {
    $cfg = Get-PublisherConfig -Path $ConfigPath
    $resolvedSrc = if ($WallpapersDir) { $WallpapersDir } else { Join-Path $PSScriptRoot $cfg.Paths.WallpapersDir }
    $resolvedPub = if ($PublishedDir) { $PublishedDir } else { Join-Path $PSScriptRoot $cfg.Paths.PublishedDir }
    $maxBytes = $cfg.Security.MaxImageSizeBytes
    $exts = $cfg.Security.AllowedExtensions
    $interval = $cfg.Slideshow.DefaultIntervalSeconds

    Write-Output "Executing wallpaper sync..."
    $res = Sync-WallpaperCollection -SourceDir $resolvedSrc -TargetDir $resolvedPub `
        -MaxSizeBytes $maxBytes -AllowedExts $exts -SlideshowInterval $interval
    if ($res) {
        Write-Output "Current Collection Version: $($res.collectionVersion)"
        Write-Output "Published Images: $($res.totalImages)"
    }
}
