$out = $PSScriptRoot;
$maps = Join-Path $out 'maps';
$idFile = Join-Path $out 'beatmapsets.txt';
$threads = 10;
$maxPerMin = 110;

$fast = @(
	@{
		Name = 'osudl';
		Url = 'https://osudl.org/s/{0}?video=false';
	},
	@{
		Name = 'nekoha';
		Url = 'https://mirror.nekoha.moe/api/download/{0}?noVideo=1';
	}
)

$fallback = @{
	Name = 'sayobot';
	Url = 'https://dl.sayobot.cn/beatmaps/download/novideo/{0}';
}

$mirrorNames = @($fast | ForEach-Object { $_.Name }) + $fallback.Name;
$cooldowns = [hashtable]::Synchronized(@{});
if (-not (Test-Path $idFile)) {
	Write-Host "beatmapsets.txt not found in $out - put one beatmapset ID per line in it and run again" -ForegroundColor Red;
	exit 1;
}

New-Item -ItemType Directory -Force $maps | Out-Null;
$ids = @(Get-Content $idFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique | Where-Object { -not (Test-Path (Join-Path $maps "$_.osz")) });
$total = $ids.Count;

"$total maps left to download, $threads threads, capped at $maxPerMin per minute";

$worker = {
	param($id, $maps, $offset, $minSeconds, $fast, $fallback, $cooldowns);
	$started = Get-Date;
	$ProgressPreference = 'SilentlyContinue';

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
	$dest = Join-Path $maps "$id.osz";
	$res = [pscustomobject]@{
		Id = $id;
		Mirror = $null;
		Bytes = 0;
		Errors = @();
	}

	if (Test-Path $dest) {
		$res.Mirror = 'existing';
		return $res;
	}

	$order = @($fast[$offset % $fast.Count], $fast[($offset + 1) % $fast.Count], $fallback);

	while ($true) {
		$now = Get-Date;
		$ready = @($order | Where-Object { -not $cooldowns[$_.Name] -or $cooldowns[$_.Name] -le $now });

		if ($ready.Count -gt 0) {
			break;
		}

		$next = $order | ForEach-Object { $cooldowns[$_.Name] } | Sort-Object | Select-Object -First 1;
		Start-Sleep -Seconds ([Math]::Max(1, [Math]::Ceiling(($next - $now).TotalSeconds)));
	}

	$errors = @();
	foreach ($m in $order) {
		if ($cooldowns[$m.Name] -and $cooldowns[$m.Name] -gt (Get-Date)) {
			continue;
		}

		try {
			Invoke-WebRequest ($m.Url -f $id) -OutFile "$dest.part" -UseBasicParsing -TimeoutSec 180;

			$fs = [IO.File]::OpenRead("$dest.part");
			$b0 = $fs.ReadByte();
			$b1 = $fs.ReadByte();
			$len = $fs.Length;
			$fs.Dispose();

			if ($b0 -eq 0x50 -and $b1 -eq 0x4B) {
				Move-Item "$dest.part" $dest -Force;
				$res.Mirror = $m.Name;
				$res.Bytes = $len;
				$cooldowns["$($m.Name)#strikes"] = 0;
				break;
			}

			$errors += "$($m.Name):notzip";
		} catch {
			$resp = $_.Exception.Response;
			$code = if ($resp) {
				[int]$resp.StatusCode;
			}
			elseif ($_.Exception.Status) {
				"$($_.Exception.Status)";
			}
			else {
				$_.Exception.GetType().Name;
			}

			$errors += "$($m.Name):$code";

			if ($code -eq 429 -or $code -eq 503) {
				$strikes = [int]$cooldowns["$($m.Name)#strikes"] + 1;
				$cooldowns["$($m.Name)#strikes"] = $strikes;
				$wait = [Math]::Min(60 * [Math]::Pow(2, $strikes - 1), 900);
				$retry = $resp.Headers.RetryAfter;

				if ($retry -and $retry.Delta) {
					$wait = $retry.Delta.TotalSeconds;
				}
				elseif ($retry -and $retry.Date) {
					$wait = ($retry.Date - [DateTimeOffset]::Now).TotalSeconds;
				}
				elseif ($resp.Headers -is [System.Net.WebHeaderCollection] -and ($resp.Headers['Retry-After'] -as [int])) {
					$wait = [int]$resp.Headers['Retry-After'];
				}

				$until = (Get-Date).AddSeconds([Math]::Max(5, [Math]::Min($wait, 3600)));

				if (-not $cooldowns[$m.Name] -or $cooldowns[$m.Name] -lt $until) {
					$cooldowns[$m.Name] = $until;
				}
			}
		}

		Remove-Item "$dest.part" -ErrorAction SilentlyContinue;
	}

	$res.Errors = $errors;

	$elapsed = ((Get-Date) - $started).TotalSeconds;
	if ($elapsed -lt $minSeconds) {
		Start-Sleep -Milliseconds ([int](($minSeconds - $elapsed) * 1000));
	}

	$res;
}

$okBy = @{};
$bytesBy = @{};
$errBy = @{};
$failed = [System.Collections.Generic.List[string]]::new();
$done = 0;
$start = Get-Date;

function Get-StatsLine {
	$perMin = if ($done -gt 0) {
		$done / ((Get-Date) - $start).TotalMinutes;
	}
	else {
		0;
	}

	$etaText = if ($perMin -gt 0) {
		$eta = [TimeSpan]::FromMinutes(($total - $done) / $perMin);
		"{0}h{1:mm}" -f [int][math]::Floor($eta.TotalHours), $eta;
	}
	else {
		'?';
	}

	$parts = foreach ($name in $mirrorNames) {
		"{0} {1} ({2:N1} GB)" -f $name, [int]$okBy[$name], ([double]$bytesBy[$name] / 1GB);
	}

	$line = "[{0:HH:mm:ss}] {1}/{2} | {3:N0}/min | ETA {4} | {5} | failed {6}" -f (Get-Date), $done, $total, $perMin, $etaText, ($parts -join ' | '), $failed.Count;
	$cooling = @(foreach ($name in $mirrorNames) {
		$until = $cooldowns[$name];

		if ($until -and $until -gt (Get-Date)) {
			"{0} {1:N0}s" -f $name, ($until - (Get-Date)).TotalSeconds;
		}
	});

	if ($cooling.Count -gt 0) {
		$line += " | cooldown: " + ($cooling -join ', ');
	}

	$line;
}

function Get-ErrorLine {
	if ($errBy.Count -eq 0) {
		return $null;
	}

	$items = $errBy.GetEnumerator() | Sort-Object Name | ForEach-Object {
		"{0} x{1}" -f ($_.Name -replace ':', ' '), $_.Value;
	}

	"           errors: " + ($items -join ' | ');
}

$logPath = Join-Path $out 'download-log.csv';
$newLog = -not (Test-Path $logPath);
$log = [IO.StreamWriter]::new($logPath, $true);
$log.AutoFlush = $true;

if ($newLog) {
	$log.WriteLine('time,id,mirror,bytes,errors');
}

$minSeconds = $threads * 60 / $maxPerMin;
$pool = [runspacefactory]::CreateRunspacePool(1, $threads);
$pool.Open();
$jobs = [System.Collections.Generic.List[object]]::new();
$n = 0;

try {
	foreach ($id in $ids) {
		$ps = [powershell]::Create().AddScript($worker).AddArgument($id).AddArgument($maps).AddArgument($n % $fast.Count).AddArgument($minSeconds).AddArgument($fast).AddArgument($fallback).AddArgument($cooldowns);
		$ps.RunspacePool = $pool;
		$jobs.Add([pscustomobject]@{
			Ps = $ps;
			Handle = $ps.BeginInvoke();
		});

		$n++;
	}

	$lastReport = Get-Date;
	while ($jobs.Count -gt 0) {
		foreach ($j in @($jobs | Where-Object { $_.Handle.IsCompleted })) {
			$r = $j.Ps.EndInvoke($j.Handle) | Select-Object -Last 1;
			$j.Ps.Dispose();
			[void]$jobs.Remove($j);
			$done++;

			if (-not $r) {
				$failed.Add('?');
				$errBy['worker:crash'] = 1 + [int]$errBy['worker:crash'];
				continue;
			}

			if ($r.Mirror) {
				$okBy[$r.Mirror] = 1 + [int]$okBy[$r.Mirror];
				$bytesBy[$r.Mirror] = [double]$bytesBy[$r.Mirror] + $r.Bytes;
			}
			else {
				$failed.Add($r.Id);
			}

			foreach ($e in $r.Errors) {
				$errBy[$e] = 1 + [int]$errBy[$e];
			}

			$log.WriteLine(("{0:s},{1},{2},{3},{4}" -f (Get-Date), $r.Id, $r.Mirror, $r.Bytes, ($r.Errors -join ' ')));
		}

		if (((Get-Date) - $lastReport).TotalSeconds -ge 10 -and $done -gt 0) {
			Write-Host (Get-StatsLine);
			$el = Get-ErrorLine;

			if ($el) {
				Write-Host $el -ForegroundColor Yellow;
			}

			$lastReport = Get-Date;
		}

		Start-Sleep -Milliseconds 500;
	}
}
finally {
	foreach ($j in $jobs) {
		if (-not $j.Handle.IsCompleted) {
			[void]$j.Ps.BeginStop($null, $null);
		}
	}

	$waitUntil = (Get-Date).AddSeconds(5);
	while ((Get-Date) -lt $waitUntil -and @($jobs | Where-Object { $_.Ps.InvocationStateInfo.State -in 'Running', 'Stopping' }).Count -gt 0) {
		Start-Sleep -Milliseconds 200;
	}

	Remove-Item (Join-Path $maps '*.part') -ErrorAction SilentlyContinue;
	[void]$pool.BeginClose($null, $null);
	$log.Dispose();

	$failed | Set-Content (Join-Path $out 'failed.txt');

	Write-Host '';
	Write-Host '===== SUMMARY =====' -ForegroundColor Cyan;
	Write-Host (Get-StatsLine);

	foreach ($name in $mirrorNames + 'existing') {
		if ($okBy[$name]) {
			Write-Host ("  {0,-9} {1,6} maps  {2,8:N2} GB" -f $name, $okBy[$name], ([double]$bytesBy[$name] / 1GB));
		}
	}

	$el = Get-ErrorLine;
	if ($el) {
		Write-Host $el.Trim() -ForegroundColor Yellow;
	}

	Write-Host "  failed: $($failed.Count) (see failed.txt), full log: download-log.csv";
}