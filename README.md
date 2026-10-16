# osu-lazer-beatmap-recovery

Re-downloads a list of osu! beatmapsets from public mirrors, in parallel, at a fixed and polite rate.

I wrote this after rebuilding my PC and losing osu!lazer's database (`client.realm`). All of the map files were still on disk in lazer's `files` folder, but without the database lazer no longer knew what any of them were. Every `.osu` file still contains its `BeatmapSetID`, so the library can be rebuilt by collecting those IDs and downloading the sets again. This script does the downloading part.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [1. Get your beatmapset IDs](#1-get-your-beatmapset-ids)
- [2. Download the maps](#2-download-the-maps)
- [3. Import them into lazer](#3-import-them-into-lazer)
- [Files it creates](#files-it-creates)
- [Mirrors](#mirrors)
- [Copyright](#copyright)

## What it does

- Reads `beatmapsets.txt` (one beatmapset ID per line) from the script's folder
- Downloads each set into `maps\<id>.osz`, without videos
- Skips sets that are already downloaded, so you can stop and restart at any time
- Spreads the work over two mirrors and falls back to a third when neither has a set
- Keeps to a fixed overall rate of 110 maps a minute, no matter how many downloads are running
- Backs off from a mirror that answers `429`/`503`, using its `Retry-After` header when it sends one
- Checks every download is a real `.osz` before keeping it
- Shows a live dashboard with progress, speed, ETA and per-mirror stats

## Requirements

- Windows with PowerShell 7 (`winget install --id Microsoft.PowerShell -e`). Windows PowerShell 5.1 works too, but can't cancel a running download on Ctrl+C.

## 1. Get your beatmapset IDs

Already have a list? Put it in `beatmapsets.txt`, one ID per line (see `beatmapsets.example.txt`), and skip to [step 2](#2-download-the-maps).

If lazer lost its database but `%APPDATA%\osu\files` is still there, this collects every `BeatmapSetID` it can find into `beatmapsets.txt`. It only opens files that start like a `.osu` file, so it gets through a large library in a few minutes:

```powershell
$ids = [System.Collections.Generic.HashSet[int]]::new();
foreach ($path in [IO.Directory]::EnumerateFiles("$env:APPDATA\osu\files", '*', 'AllDirectories')) {
	$fs = [IO.File]::OpenRead($path);
	$buf = [byte[]]::new(32);
	$n = $fs.Read($buf, 0, 32);
	$fs.Dispose();

	if (-not [Text.Encoding]::UTF8.GetString($buf, 0, $n).TrimStart([char]0xFEFF).StartsWith('osu file format')) {
		continue;
	}

	$m = Select-String -LiteralPath $path -Pattern '^\s*BeatmapSetID\s*:\s*(\d+)' -List;
	if ($m -and [int]$m.Matches[0].Groups[1].Value -gt 0) {
		[void]$ids.Add([int]$m.Matches[0].Groups[1].Value);
	}
}

$ids | Sort-Object | Set-Content beatmapsets.txt;
```

Very old maps don't have a `BeatmapSetID` line. Those can't be found this way.

## 2. Download the maps

1. Put `osu-download-parallel.ps1` and your `beatmapsets.txt` together in a folder.
2. Open PowerShell 7 in that folder and run:

   ```powershell
   pwsh -File .\osu-download-parallel.ps1
   ```

If PowerShell refuses with *"is not digitally signed"*, that's because Windows marks files downloaded from the internet. Unblock the script once and run it again:

```powershell
Unblock-File .\osu-download-parallel.ps1
```

Stop it with Ctrl+C whenever you like. Finished maps are kept and the next run continues where it left off. Sets that every mirror failed on end up in `failed.txt`; run the script again later to retry them.

## 3. Import them into lazer

Drag the `.osz` files onto the osu!lazer window. Lazer deletes each `.osz` after importing it, so import a copy if you want to keep the originals. Lazer stores files by hash, so sets whose files are still in your `files` folder take up hardly any extra space.

## Files it creates

All next to the script:

| File | What's in it |
|---|---|
| `maps\` | The downloaded `.osz` files |
| `failed.txt` | IDs that no mirror could deliver in the last run |
| `download-log.csv` | One line per set: time, ID, mirror, size, errors and download time |

## Mirrors

Thanks to the people running these. They do it for free, so please don't raise the rate or the thread count in the script.

| Mirror | Used for |
|---|---|
| [osu!dl](https://osudl.org) | main (ranked, approved and loved sets) |
| [Nekoha](https://mirror.nekoha.moe) | main |
| [Sayobot](https://osu.sayobot.cn) | fallback |

## Copyright

The maps themselves belong to their mappers and the songs to their artists. This tool only downloads what the mirrors already offer publicly.