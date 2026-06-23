[CmdletBinding()]
param(
    [string]$SourceCorpus = "C:\Users\chipp\OneDrive\Documents\fanyahanwen-corpus\corpus",
    [string]$AuditCsv = "C:\Users\chipp\OneDrive\Documents\fanyahanwen-corpus\linux_filename_audit.csv",
    [string]$StagingCorpus = "C:\fanya-production-staging\corpus",
    [string]$PlanCsv = "C:\fanya-production-staging\production_filename_mapping.csv",
    [int]$MaximumDeployedNameBytes = 240,
    [switch]$Apply,
    [switch]$ReplaceStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Utf8StrictNoBom = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Get-Utf8ByteCount {
    param([Parameter(Mandatory = $true)][string]$Text)
    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function Get-Sha256Prefix {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Length = 12
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, $Length)
    }
    finally {
        $sha.Dispose()
    }
}

function Truncate-Utf8Safely {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$MaximumBytes
    )

    if ((Get-Utf8ByteCount -Text $Text) -le $MaximumBytes) {
        return $Text
    }

    $builder = New-Object System.Text.StringBuilder
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)

    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        $candidate = $builder.ToString() + $element

        if ((Get-Utf8ByteCount -Text $candidate) -gt $MaximumBytes) {
            break
        }

        [void]$builder.Append($element)
    }

    return $builder.ToString()
}

function Get-TextEncodingInfo {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        return [PSCustomObject]@{
            Encoding = $Utf8Bom
            PreambleLength = 3
            Name = "UTF-8 BOM"
        }
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [PSCustomObject]@{
            Encoding = [System.Text.Encoding]::Unicode
            PreambleLength = 2
            Name = "UTF-16 LE"
        }
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [PSCustomObject]@{
            Encoding = [System.Text.Encoding]::BigEndianUnicode
            PreambleLength = 2
            Name = "UTF-16 BE"
        }
    }

    # Corpus text should be UTF-8. The strict decoder makes the script stop
    # rather than silently corrupting a file that uses some other encoding.
    [void]$Utf8StrictNoBom.GetString($Bytes)

    return [PSCustomObject]@{
        Encoding = $Utf8NoBom
        PreambleLength = 0
        Name = "UTF-8"
    }
}

function Add-PageTitleHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PageTitle,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encodingInfo = Get-TextEncodingInfo -Bytes $bytes

    $contentLength = $bytes.Length - $encodingInfo.PreambleLength
    $contentBytes = New-Object byte[] $contentLength
    if ($contentLength -gt 0) {
        [Array]::Copy(
            $bytes,
            $encodingInfo.PreambleLength,
            $contentBytes,
            0,
            $contentLength
        )
    }

    $text = $encodingInfo.Encoding.GetString($contentBytes)

    if ($text -match '(?m)^#\s*PAGE_TITLE\s*:') {
        [System.IO.File]::Copy($Path, $OutputPath, $false)
        return "already present"
    }

    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Text.RegularExpressions.Regex]::Split($text, "\r\n|\n|\r")

    $leadingHeaderEnd = 0
    while ($leadingHeaderEnd -lt $lines.Length -and $lines[$leadingHeaderEnd] -match '^#\s*[^:]+\s*:') {
        $leadingHeaderEnd++
    }

    $titleHeaderIndex = -1
    for ($index = 0; $index -lt $leadingHeaderEnd; $index++) {
        if ($lines[$index] -match '^#\s*TITLE\s*:') {
            $titleHeaderIndex = $index
            break
        }
    }

    $insertIndex = if ($titleHeaderIndex -ge 0) {
        $titleHeaderIndex + 1
    }
    else {
        $leadingHeaderEnd
    }

    $newLines = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($index -eq $insertIndex) {
            $newLines.Add("# PAGE_TITLE: $PageTitle")
        }
        $newLines.Add($lines[$index])
    }

    if ($insertIndex -eq $lines.Length) {
        $newLines.Add("# PAGE_TITLE: $PageTitle")
    }

    $newText = [string]::Join($newline, $newLines)
    $newContentBytes = $encodingInfo.Encoding.GetBytes($newText)
    $preamble = $encodingInfo.Encoding.GetPreamble()

    $outputBytes = New-Object byte[] ($preamble.Length + $newContentBytes.Length)
    if ($preamble.Length -gt 0) {
        [Array]::Copy($preamble, 0, $outputBytes, 0, $preamble.Length)
    }
    [Array]::Copy(
        $newContentBytes,
        0,
        $outputBytes,
        $preamble.Length,
        $newContentBytes.Length
    )

    [System.IO.File]::WriteAllBytes($OutputPath, $outputBytes)
    return "added"
}

function Get-DeployedFileName {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalRelativePath,
        [Parameter(Mandatory = $true)][string]$OriginalName
    )

    if ($OriginalName -match '^(.*)__juan_([0-9]+)\.txt$') {
        return "juan_$($Matches[2]).txt"
    }

    $extension = [System.IO.Path]::GetExtension($OriginalName)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($OriginalName)
    $hash = Get-Sha256Prefix -Text $OriginalRelativePath -Length 12
    $suffix = "__$hash$extension"
    $availablePrefixBytes = $MaximumDeployedNameBytes - (Get-Utf8ByteCount -Text $suffix)

    if ($availablePrefixBytes -lt 1) {
        throw "MaximumDeployedNameBytes is too small for the required suffix."
    }

    $shortStem = Truncate-Utf8Safely -Text $stem -MaximumBytes $availablePrefixBytes
    return "$shortStem$suffix"
}

function Convert-ToLongPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.StartsWith('\\?\')) {
        return $Path
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\')) {
        return '\\?\UNC\' + $fullPath.Substring(2)
    }
    return '\\?\' + $fullPath
}

$SourceCorpus = [System.IO.Path]::GetFullPath($SourceCorpus)
$AuditCsv = [System.IO.Path]::GetFullPath($AuditCsv)
$StagingCorpus = [System.IO.Path]::GetFullPath($StagingCorpus)
$PlanCsv = [System.IO.Path]::GetFullPath($PlanCsv)

if (-not [System.IO.Directory]::Exists($SourceCorpus)) {
    throw "Source corpus does not exist: $SourceCorpus"
}

if (-not [System.IO.File]::Exists($AuditCsv)) {
    throw "Audit CSV does not exist: $AuditCsv"
}

if ($MaximumDeployedNameBytes -gt 255) {
    throw "MaximumDeployedNameBytes cannot exceed Linux's 255-byte filename limit."
}

$blockedRows = Import-Csv -LiteralPath $AuditCsv |
    Where-Object {
        $_.Status -eq 'BLOCKED' -and
        $_.Type -eq 'file' -and
        $_.RelativePath -match '(^|\\)clean(\\|$)'
    }

if ($blockedRows.Count -eq 0) {
    throw "The audit contains no blocked clean files. Nothing needs normalising."
}

$plan = New-Object System.Collections.Generic.List[object]

foreach ($row in $blockedRows) {
    $originalRelativePath = $row.RelativePath
    $originalName = [System.IO.Path]::GetFileName($originalRelativePath)
    $relativeDirectory = [System.IO.Path]::GetDirectoryName($originalRelativePath)
    $deployedName = Get-DeployedFileName `
        -OriginalRelativePath $originalRelativePath `
        -OriginalName $originalName

    $deployedRelativePath = [System.IO.Path]::Combine($relativeDirectory, $deployedName)
    $sourcePath = [System.IO.Path]::Combine($SourceCorpus, $originalRelativePath)
    $sourceCollisionPath = [System.IO.Path]::Combine($SourceCorpus, $deployedRelativePath)

    if (-not [System.IO.File]::Exists((Convert-ToLongPath -Path $sourcePath))) {
        throw "Audited source file is missing: $originalRelativePath"
    }

    if ($deployedRelativePath -ne $originalRelativePath -and
        [System.IO.File]::Exists((Convert-ToLongPath -Path $sourceCollisionPath))) {
        throw "The planned deployed name already exists in the source corpus: $deployedRelativePath"
    }

    $action = if ($originalName -match '__juan_[0-9]+\.txt$') {
        'shorten repeated juan filename'
    }
    else {
        'shorten filename and add PAGE_TITLE to staging copy'
    }

    $pageTitle = if ($action -like '*PAGE_TITLE*') {
        [System.IO.Path]::GetFileNameWithoutExtension($originalName)
    }
    else {
        ''
    }

    $plan.Add([PSCustomObject]@{
        OriginalRelativePath = $originalRelativePath
        DeployedRelativePath = $deployedRelativePath
        OriginalNameBytes = [int]$row.NameBytes
        DeployedNameBytes = Get-Utf8ByteCount -Text $deployedName
        Action = $action
        PageTitleAdded = if ($pageTitle) { $pageTitle } else { '' }
    })
}

$duplicateDestinations = $plan |
    Group-Object DeployedRelativePath |
    Where-Object Count -gt 1

if ($duplicateDestinations) {
    $duplicates = ($duplicateDestinations.Name -join "`n")
    throw "Two source files would map to the same deployed path:`n$duplicates"
}

$planDirectory = [System.IO.Path]::GetDirectoryName($PlanCsv)
if (-not [System.IO.Directory]::Exists($planDirectory)) {
    [void][System.IO.Directory]::CreateDirectory($planDirectory)
}

$plan |
    Sort-Object OriginalRelativePath |
    Export-Csv -LiteralPath $PlanCsv -NoTypeInformation -Encoding UTF8

Write-Host "Production filename plan written to:"
Write-Host "  $PlanCsv"
Write-Host
Write-Host "Blocked clean files planned: $($plan.Count)"
Write-Host "Raw blocked files ignored:   $((Import-Csv -LiteralPath $AuditCsv | Where-Object { $_.Status -eq 'BLOCKED' -and $_.RelativePath -match '(^|\\)raw(\\|$)' }).Count)"
Write-Host

$plan |
    Select-Object OriginalNameBytes, DeployedNameBytes, Action, OriginalRelativePath, DeployedRelativePath |
    Format-Table -AutoSize

if (-not $Apply) {
    Write-Host
    Write-Host "DRY RUN ONLY. No corpus files were copied or changed."
    Write-Host "Review the CSV, then rerun with -Apply."
    exit 0
}

if ([System.IO.Directory]::Exists($StagingCorpus)) {
    if (-not $ReplaceStaging) {
        throw "Staging directory already exists. Use -ReplaceStaging to delete and rebuild it: $StagingCorpus"
    }

    Write-Host "Removing existing staging directory: $StagingCorpus"
    [System.IO.Directory]::Delete((Convert-ToLongPath -Path $StagingCorpus), $true)
}

[void][System.IO.Directory]::CreateDirectory($StagingCorpus)

Write-Host
Write-Host "Copying direct */clean trees into production staging..."
Write-Host "Raw directories, scripts, local indexes, and other non-clean material are not copied."
Write-Host

$sourceTopDirectories = Get-ChildItem -LiteralPath $SourceCorpus -Directory -Force
$copiedCleanRoots = 0

foreach ($topDirectory in $sourceTopDirectories) {
    $cleanSource = [System.IO.Path]::Combine($topDirectory.FullName, 'clean')

    if (-not [System.IO.Directory]::Exists($cleanSource)) {
        continue
    }

    $cleanDestination = [System.IO.Path]::Combine(
        $StagingCorpus,
        $topDirectory.Name,
        'clean'
    )

    [void][System.IO.Directory]::CreateDirectory($cleanDestination)

    Write-Host "Copying $($topDirectory.Name)\clean"

    & robocopy.exe `
        $cleanSource `
        $cleanDestination `
        /E `
        /COPY:DAT `
        /DCOPY:DAT `
        /R:2 `
        /W:1 `
        /XJ `
        /MT:8 `
        /NFL `
        /NDL `
        /NP

    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "Robocopy failed for $cleanSource with exit code $robocopyExitCode"
    }

    $copiedCleanRoots++
}

if ($copiedCleanRoots -eq 0) {
    throw "No direct */clean trees were found beneath $SourceCorpus"
}

Write-Host
Write-Host "Normalising the $($plan.Count) Linux-incompatible filenames in staging..."

foreach ($entry in $plan) {
    $oldStagingPath = [System.IO.Path]::Combine(
        $StagingCorpus,
        $entry.OriginalRelativePath
    )
    $newStagingPath = [System.IO.Path]::Combine(
        $StagingCorpus,
        $entry.DeployedRelativePath
    )

    $oldLongPath = Convert-ToLongPath -Path $oldStagingPath
    $newLongPath = Convert-ToLongPath -Path $newStagingPath

    if (-not [System.IO.File]::Exists($oldLongPath)) {
        throw "Expected copied staging file is missing: $($entry.OriginalRelativePath)"
    }

    if ([System.IO.File]::Exists($newLongPath)) {
        throw "Refusing to overwrite an existing staging file: $($entry.DeployedRelativePath)"
    }

    if ($entry.Action -eq 'shorten repeated juan filename') {
        [System.IO.File]::Move($oldLongPath, $newLongPath)
    }
    else {
        $pageTitleStatus = Add-PageTitleHeader `
            -Path $oldLongPath `
            -PageTitle $entry.PageTitleAdded `
            -OutputPath $newLongPath

        if (-not [System.IO.File]::Exists($newLongPath)) {
            throw "Failed to write normalised staging copy: $($entry.DeployedRelativePath)"
        }

        [System.IO.File]::Delete($oldLongPath)
        Write-Host "PAGE_TITLE ${pageTitleStatus}: $($entry.DeployedRelativePath)"
    }
}

Write-Host
Write-Host "Verifying that every staged filename component fits Linux..."

$remainingBlocked = New-Object System.Collections.Generic.List[object]
$directoryStack = New-Object 'System.Collections.Generic.Stack[string]'
$directoryStack.Push($StagingCorpus)

while ($directoryStack.Count -gt 0) {
    $directory = $directoryStack.Pop()

    foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries((Convert-ToLongPath -Path $directory))) {
        $name = [System.IO.Path]::GetFileName($entryPath)
        $nameBytes = Get-Utf8ByteCount -Text $name

        if ($nameBytes -gt 255) {
            $remainingBlocked.Add([PSCustomObject]@{
                NameBytes = $nameBytes
                Path = $entryPath
            })
        }

        if ([System.IO.Directory]::Exists($entryPath)) {
            $directoryStack.Push($entryPath)
        }
    }
}

if ($remainingBlocked.Count -gt 0) {
    $remainingReport = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($PlanCsv),
        'remaining_linux_blocked_names.csv'
    )
    $remainingBlocked | Export-Csv -LiteralPath $remainingReport -NoTypeInformation -Encoding UTF8
    throw "The staging tree still has Linux-incompatible names. See: $remainingReport"
}

Write-Host
Write-Host "Production corpus staging is complete."
Write-Host "Staging root:"
Write-Host "  $StagingCorpus"
Write-Host "Mapping CSV (kept outside the deployable corpus tree):"
Write-Host "  $PlanCsv"
Write-Host
Write-Host "Nothing in the master corpus was renamed or edited."

