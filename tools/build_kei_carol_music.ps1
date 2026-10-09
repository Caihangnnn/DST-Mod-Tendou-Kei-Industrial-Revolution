param(
    [string]$MusicExtractionDir = "",
    [string]$AddonOutputDir = "",
    [string]$Ffmpeg = "",
    [Alias("FsBankEx")]
    [string]$FsBank = "",
    [ValidateSet("mp3", "vorbis")]
    [string]$Codec = "mp3",
    [ValidateRange(0, 100)]
    [int]$Mp3Quality = 75,
    [ValidateRange(0, 100)]
    [int]$VorbisQuality = 50
)

$ErrorActionPreference = "Stop"

function Resolve-Tool([string]$explicitPath, [string]$commandName, [string]$fallbackPath) {
    if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
        if (-not (Test-Path -LiteralPath $explicitPath -PathType Leaf)) {
            throw "Tool not found: $explicitPath"
        }
        return (Resolve-Path -LiteralPath $explicitPath).Path
    }
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($command -ne $null) {
        return $command.Source
    }
    if ($fallbackPath -ne "" -and (Test-Path -LiteralPath $fallbackPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $fallbackPath).Path
    }
    throw "Tool not found: $commandName"
}

$ffmpegPath = Resolve-Tool $Ffmpeg "ffmpeg" "C:\Users\caiha\AppData\Roaming\TRAE SOLO\ModularData\ai-agent\vm\tools\app\ffmpeg\ffmpeg.exe"
$fsbankCommand = if ($Codec -eq "vorbis") { "fsbankcl" } else { "fsbankexcl" }
$fsbankFallback = if ($Codec -eq "vorbis") {
    "C:\Users\caiha\AppData\Local\Temp\fsbankcl-runtime\fsbankcl.exe"
} else {
    "C:\Users\caiha\AppData\Local\Temp\fsbank-old\fsbankexcl.exe"
}
$fsbankPath = Resolve-Tool $FsBank $fsbankCommand $fsbankFallback
$expectedToolName = if ($Codec -eq "vorbis") { "fsbankcl.exe" } else { "fsbankexcl.exe" }
if ([IO.Path]::GetFileName($fsbankPath) -ine $expectedToolName) {
    throw "Codec '$Codec' requires $expectedToolName; got $fsbankPath"
}
$audioFormat = if ($Codec -eq "vorbis") { "FSB5 Vorbis quality $VorbisQuality" } else { "FSB5 MP3 quality $Mp3Quality" }
$musicPath = if (-not [string]::IsNullOrWhiteSpace($MusicExtractionDir)) { $MusicExtractionDir } else { Join-Path $PSScriptRoot "..\..\kei_carol_music_extract" }
$musicRoot = Convert-Path -LiteralPath $musicPath
$repoRoot = Convert-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$soundRoot = Join-Path $repoRoot "sound"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tendou-kei-carol-build-" + [guid]::NewGuid().ToString("N"))
$cacheRoot = Join-Path $tempRoot "fsbank-cache"
$manifestPath = Join-Path $musicRoot "manifest.json"
$templatePath = Join-Path $repoRoot "..\Reference\Takanashi Hoshino\sound\hoshino_sound.fev"
$addonRoot = if (-not [string]::IsNullOrWhiteSpace($AddonOutputDir)) {
    [IO.Path]::GetFullPath($AddonOutputDir)
} else {
    Join-Path (Split-Path $repoRoot -Parent) "Tendou-Kei-Music-Patch"
}
$addonSoundRoot = Join-Path $addonRoot "sound"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest.json was not found in $musicRoot"
}
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "Reference FEV was not found: $templatePath"
}
foreach ($modRoot in @($repoRoot, $addonRoot)) {
    $modRootFull = [IO.Path]::GetFullPath($modRoot).TrimEnd('\') + '\'
    $tempRootFull = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\') + '\'
    if ($tempRootFull.StartsWith($modRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Temporary build directory must remain outside mod directories: $tempRoot"
    }
}

try {
$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$items = if ($manifest -is [array]) { @($manifest) } else { @($manifest.items) }
if ($items.Count -ne 53) {
    throw "Expected 53 Carol tracks, found $($items.Count)"
}
foreach ($item in $items) {
    if ([string]::IsNullOrWhiteSpace($item.filename)) {
        throw "Carol manifest contains an item without a filename"
    }
}

# Each FEV exposes twenty event names, so every bank preserves all twenty FSB
# slots. Unused slots point to short silent samples; Lua exposes only real tracks.
# Five optional banks keep each upload under 100 MB.
$slotNames = @(
    "attacked_1", "attacked_2", "attacked_3", "christmas_carol", "death",
    "do_emote", "drown_in_water", "feel_sleepy", "ghost_1", "ghost_2",
    "ghost_3", "ghost_4", "ghost_5", "pose", "talk_1", "talk_2",
    "talk_3", "talk_4", "talk_5", "yawn"
)
$bankDefs = @(
    [pscustomobject]@{ name = "kei_carol_a01"; start = 0; count = 5; output = $repoRoot },
    [pscustomobject]@{ name = "kei_carol_b01"; start = 5; count = 10; output = $addonRoot },
    [pscustomobject]@{ name = "kei_carol_b02"; start = 15; count = 10; output = $addonRoot },
    [pscustomobject]@{ name = "kei_carol_b03"; start = 25; count = 10; output = $addonRoot },
    [pscustomobject]@{ name = "kei_carol_b04"; start = 35; count = 10; output = $addonRoot },
    [pscustomobject]@{ name = "kei_carol_b05"; start = 45; count = 8; output = $addonRoot }
)

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
New-Item -ItemType Directory -Path $soundRoot -Force | Out-Null
New-Item -ItemType Directory -Path $addonSoundRoot -Force | Out-Null

$oldNamespace = [Text.Encoding]::ASCII.GetBytes("hoshino_sound")
$builtBanks = @()
foreach ($bankDef in $bankDefs) {
    $bankName = $bankDef.name
    $trackCount = $bankDef.count
    $sourceStart = $bankDef.start
    $outputRoot = $bankDef.output
    $bankSoundRoot = if ($outputRoot -eq $repoRoot) { $soundRoot } else { $addonSoundRoot }
    $bankTempRoot = Join-Path $tempRoot $bankName
    New-Item -ItemType Directory -Path $bankTempRoot -Force | Out-Null
    $listEntries = @()
    $trackMapping = @()
    $silentPath = Join-Path $bankTempRoot "silent.wav"
    & $ffmpegPath -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.05 -c:a pcm_s16le $silentPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $silentPath -PathType Leaf)) {
        throw "FFmpeg failed to create silent FEV placeholder sample for $bankName"
    }

    for ($slotIndex = 0; $slotIndex -lt $slotNames.Count; $slotIndex++) {
        # Preserve the event layout expected by the shared reference FEV.
        $slotEvent = $slotNames[$slotIndex]
        $wavPath = Join-Path $bankTempRoot ($slotEvent + ".wav")
        $source = $null
        if ($slotIndex -lt $trackCount) {
            $source = $items[$sourceStart + $slotIndex]
            $sourcePath = Join-Path $musicRoot $source.filename
            & $ffmpegPath -hide_banner -loglevel error -y -i $sourcePath -ac 2 -ar 44100 -c:a pcm_s16le $wavPath
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wavPath -PathType Leaf)) {
                throw "FFmpeg failed for $($source.filename)"
            }
        } else {
            Copy-Item -LiteralPath $silentPath -Destination $wavPath -Force
        }
        $listEntries += ($slotEvent + ".wav")
        if ($slotIndex -lt $trackCount) {
            $trackMapping += [pscustomobject]@{
                slot = $slotEvent
                ordinal = $source.ordinal
                id = $source.id
                title = $source.title
                source_url = $source.source_url
                filename = $source.filename
            }
        }
    }

    $listPath = Join-Path $bankTempRoot ($bankName + ".lst")
    $listEntries | Set-Content -LiteralPath $listPath -Encoding ascii
    $fsbPath = Join-Path $bankTempRoot ($bankName + ".fsb")
    if (Test-Path -LiteralPath $fsbPath -PathType Leaf) {
        Remove-Item -LiteralPath $fsbPath -Force
    }
    Push-Location $bankTempRoot
    try {
        if ($Codec -eq "vorbis") {
            # fsbankcl 2.01.09 parses cache_dir correctly only after the source list.
            & $fsbankPath -format vorbis -quality $VorbisQuality -build_mode s -rebuild -o $fsbPath (Split-Path $listPath -Leaf) -cache_dir $cacheRoot
        } else {
            & $fsbankPath -format mp3 -quality $Mp3Quality -build_mode s -rebuild -o $fsbPath (Split-Path $listPath -Leaf)
        }
        $fsbankExitCode = $LASTEXITCODE
        $fsbHeader = $null
        if (Test-Path -LiteralPath $fsbPath -PathType Leaf) {
            $fsbHeader = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($fsbPath)[0..3])
        }
        if ($fsbankExitCode -ne 0 -or -not (Test-Path -LiteralPath $fsbPath -PathType Leaf) -or $fsbHeader -ne "FSB5") {
            throw "FSBank failed to build a valid FSB5 bank: $fsbPath"
        }
    }
    finally {
        Pop-Location
    }

    $fevBytes = [IO.File]::ReadAllBytes($templatePath)
    $newNamespace = [Text.Encoding]::ASCII.GetBytes($bankName)
    if ($newNamespace.Length -ne $oldNamespace.Length) {
        throw "Bank namespace must be $($oldNamespace.Length) bytes: $bankName"
    }
    $replacements = 0
    for ($i = 0; $i -le $fevBytes.Length - $oldNamespace.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $oldNamespace.Length; $j++) {
            if ($fevBytes[$i + $j] -ne $oldNamespace[$j]) {
                $match = $false
                break
            }
        }
        if ($match) {
            [Array]::Copy($newNamespace, 0, $fevBytes, $i, $newNamespace.Length)
            $replacements++
            $i += $oldNamespace.Length - 1
        }
    }
    if ($replacements -eq 0) {
        throw "Could not find the FEV namespace to replace for $bankName"
    }
    $fevPath = Join-Path $bankTempRoot ($bankName + ".fev")
    [IO.File]::WriteAllBytes($fevPath, $fevBytes)
    $outputSoundPath = Join-Path $bankSoundRoot ($bankName + ".fsb")
    $outputFevPath = Join-Path $bankSoundRoot ($bankName + ".fev")
    Copy-Item -LiteralPath $fsbPath -Destination $outputSoundPath -Force
    Copy-Item -LiteralPath $fevPath -Destination $outputFevPath -Force
    $builtBanks += [pscustomobject]@{
        name = $bankName
        count = $trackCount
        sample_count = $slotNames.Count
        namespace = "$bankName/$bankName"
        bank = "sound/$bankName.fsb"
        fev = "sound/$bankName.fev"
        mapping = $trackMapping
    }
}

$mainManifest = [pscustomobject]@{
    source = "https://kivo.wiki/music/"
    language = "日文/日配曲目"
    format = "$audioFormat, source normalized to stereo 44100 Hz"
    tracks = @($items | Select-Object -First 5)
    banks = @($builtBanks | Where-Object { $_.name -eq "kei_carol_a01" })
}
$addonManifest = [pscustomobject]@{
    source = "https://kivo.wiki/music/"
    language = "日文/日配曲目"
    format = "$audioFormat, source normalized to stereo 44100 Hz"
    tracks = @($items | Select-Object -Skip 5)
    banks = @($builtBanks | Where-Object { $_.name -like "kei_carol_b*" })
}
$mainManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $soundRoot "kei_carol_manifest.json") -Encoding utf8
$addonManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $addonRoot "kei_carol_manifest.json") -Encoding utf8

# Remove the two old base-mod banks only after all replacement banks were
# encoded and copied successfully. They previously held songs 6-53.
foreach ($obsolete in @("kei_carol_a02", "kei_carol_a03")) {
    Remove-Item -LiteralPath (Join-Path $soundRoot ($obsolete + ".fsb")) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $soundRoot ($obsolete + ".fev")) -Force -ErrorAction SilentlyContinue
}

Write-Host "Built one base bank (5 tracks) and five patch banks (48 tracks)"
$builtBanks | ForEach-Object {
    Write-Host "Built $($_.name): $($_.count) tracks"
}

}
finally {
if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
}
