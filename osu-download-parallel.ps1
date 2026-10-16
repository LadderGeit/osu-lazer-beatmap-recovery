$out = $PSScriptRoot;
$maps = Join-Path $out 'maps';
$idFile = Join-Path $out 'beatmapsets.txt';
$threads = 16;
$maxPerMin = 110;
$userAgent = 'osu-lazer-beatmap-recovery/1.0 (+https://github.com/LadderGeit/osu-lazer-beatmap-recovery)';

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

Write-Host '';
$startMessage = '  Starting up - reading beatmapsets.txt and checking which maps you already have...';
Write-Host $startMessage -ForegroundColor DarkGray;

New-Item -ItemType Directory -Force $maps | Out-Null;
$have = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-ChildItem $maps -Filter '*.osz' -File | ForEach-Object { $_.BaseName }));
$seen = [System.Collections.Generic.HashSet[string]]::new();
$ids = @(Get-Content $idFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' -and $seen.Add($_) -and -not $have.Contains($_) });
$total = $ids.Count;


$worker = {
	param($id, $maps, $offset, $gapSeconds, $fast, $fallback, $cooldowns, $userAgent);
	$ProgressPreference = 'SilentlyContinue';

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
	$dest = Join-Path $maps "$id.osz";
	$res = [pscustomobject]@{
		Id = $id;
		Mirror = $null;
		Bytes = 0;
		Seconds = 0;
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

	[System.Threading.Monitor]::Enter($cooldowns.SyncRoot);
	try {
		$slot = [Math]::Max((Get-Date).Ticks, [long]$cooldowns['#next']);
		$cooldowns['#next'] = $slot + [long]($gapSeconds * 10000000);
	} finally {
		[System.Threading.Monitor]::Exit($cooldowns.SyncRoot);
	}

	$wait = ($slot - (Get-Date).Ticks) / 10000;
	if ($wait -gt 0) {
		Start-Sleep -Milliseconds ([int]$wait);
	}

	$errors = @();
	foreach ($m in $order) {
		if ($cooldowns[$m.Name] -and $cooldowns[$m.Name] -gt (Get-Date)) {
			continue;
		}

		try {
			$sw = [Diagnostics.Stopwatch]::StartNew();
			Invoke-WebRequest ($m.Url -f $id) -OutFile "$dest.part" -UserAgent $userAgent -UseBasicParsing -TimeoutSec 180;

			$fs = [IO.File]::OpenRead("$dest.part");
			$b0 = $fs.ReadByte();
			$b1 = $fs.ReadByte();
			$len = $fs.Length;
			$fs.Dispose();

			if ($b0 -eq 0x50 -and $b1 -eq 0x4B) {
				Move-Item "$dest.part" $dest -Force;
				$res.Mirror = $m.Name;
				$res.Bytes = $len;
				$res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1);
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
	$res;
}

$okBy = @{};
$bytesBy = @{};
$errBy = @{};
$durBy = @{};
$failed = [System.Collections.Generic.List[string]]::new();
$done = 0;
$start = Get-Date;

$phase = 'preparing';

function Format-Span {
	param($span);

	if ($null -eq $span) {
		return '?';
	}

	"{0}h{1:mm}m" -f [int][Math]::Floor($span.TotalHours), $span;
}

function Get-DashboardLines {
	$now = Get-Date;
	$elapsed = $now - $start;
	$perMin = if ($elapsed.TotalMinutes -gt 0) {
		$done / $elapsed.TotalMinutes;
	}
	else {
		0;
	}

	$eta = if ($perMin -gt 0) {
		[TimeSpan]::FromMinutes(($total - $done) / $perMin);
	}
	else {
		$null;
	}

	$ratio = if ($total -gt 0) {
		$done / $total;
	}
	else {
		1;
	}

	$filled = [int][Math]::Floor($ratio * 30);
	$bar = $c.Pink + ([string]$g.Fill * $filled) + $c.Dim + ([string]$g.Empty * (30 - $filled)) + $c.Reset;
	$phaseText = switch -Wildcard ($phase) {
		'running' { $c.Green + $g.Dot + ' running' + $c.Reset }
		'preparing*' { $c.Cyan + $g.Dot + ' ' + $phase + $c.Reset }
		'finished' { $c.Green + $g.Check + ' finished' + $c.Reset }
		default { $c.Yellow + $g.Dot + ' ' + $phase + $c.Reset }
	}

	'';
	"  {0}{1}osu!{2}{0}{6} beatmap recovery{2}   {3}{4:HH:mm:ss}{2}   {5}" -f $c.Bold, $c.Pink, $c.Reset, $c.Dim, $now, $phaseText, $c.Orange;
	'  ' + $c.Dim + ([string]$g.Rule * 76) + $c.Reset;
	"  {0}Progress{1}  {2}{3,7}{1} / {4,-7} {2}{5,7:P1}{1}   {6}" -f $c.Dim, $c.Reset, $c.Bold, $done, $total, $ratio, $bar;
	"  {0}Speed{1}     {2}{3,7:N0}{1} /min      {0}ETA{1} {4,-9} {0}elapsed{1} {5,-9} {0}limit{1} {6}/min" -f $c.Dim, $c.Reset, $c.Bold, $perMin, (Format-Span $eta), (Format-Span $elapsed), $maxPerMin;
	'';
	"  {0}{1,-9} {2,7} {3,10} {4,6}   {5,-22} {6}{7}" -f $c.Dim, 'Mirror', 'Maps', 'Size', 'Avg', 'Errors', 'Status', $c.Reset;

	foreach ($name in $mirrorNames) {
		$errs = @($errBy.GetEnumerator() | Where-Object { $_.Name -like "${name}:*" } | Sort-Object Name | ForEach-Object {
			"{0} x{1}" -f $_.Name.Split(':')[1], $_.Value;
		});

		$errText = if ($errs.Count -gt 0) {
			$errs -join ', ';
		}
		else {
			'-';
		}

		if ($errText.Length -gt 22) {
			$errText = $errText.Substring(0, 19) + '...';
		}

		$avgText = if ($durBy[$name] -and $durBy[$name].Count -gt 0) {
			"{0:N1}s" -f ($durBy[$name] | Measure-Object -Average).Average;
		}
		else {
			'-';
		}

		$errColor = if ($errs.Count -gt 0) {
			$c.Yellow;
		}
		else {
			$c.Dim;
		}

		$until = $cooldowns[$name];
		$status = if ($until -and $until -gt $now) {
			"{0}{1} cooldown {2:N0}s{3}" -f $c.Yellow, $g.Dot, ($until - $now).TotalSeconds, $c.Reset;
		}
		else {
			"{0}{1} ok{2}" -f $c.Green, $g.Dot, $c.Reset;
		}

		"  {0}{1,-9}{2} {3,7} {4,7:N1} GB {8,6}   {5}{6,-22}{2} {7}" -f $c.Bold, $name, $c.Reset, [int]$okBy[$name], ([double]$bytesBy[$name] / 1GB), $errColor, $errText, $status, $avgText;
	}

	$failColor = if ($failed.Count -gt 0) {
		$c.Red;
	}
	else {
		$c.Green;
	}

	'';
	"  {0}Failed{1}    {2}{3,7}{1}      {0}Skipped{1} {4,-7}  {0}Crashed{1} {5}" -f $c.Dim, $c.Reset, $failColor, $failed.Count, [int]$okBy['existing'], [int]$errBy['worker:crash'];
	'  ' + $c.Dim + ([string]$g.Rule * 76) + $c.Reset;
	'  ' + $c.Dim + 'Ctrl+C stops safely - finished maps are kept and the next run continues' + $c.Reset;
}

function Show-Dashboard {
	$lines = @(Get-DashboardLines);

	if (-not $interactive) {
		$lines | ForEach-Object { Write-Host $_ };
		return;
	}

	[Console]::SetCursorPosition(0, $dashTop);

	if ($useColor) {
		foreach ($line in $lines) {
			[Console]::Write($line + $c.Reset + $c.ClearLine + "`n");
		}

		return;
	}

	$width = [Math]::Max(40, [Console]::WindowWidth - 1);
	foreach ($line in $lines) {
		$text = if ($line.Length -gt $width) {
			$line.Substring(0, $width);
		}
		else {
			$line.PadRight($width);
		}

		[Console]::WriteLine($text);
	}
}

$logPath = Join-Path $out 'download-log.csv';
$newLog = -not (Test-Path $logPath);
$log = [IO.StreamWriter]::new($logPath, $true);
$log.AutoFlush = $true;

if ($newLog) {
	$log.WriteLine('time,id,mirror,bytes,errors,seconds');
}

$gapSeconds = 60 / $maxPerMin;
$pool = [runspacefactory]::CreateRunspacePool(1, $threads);
$pool.Open();
$jobs = [System.Collections.Generic.List[object]]::new();
$n = 0;
$interactive = -not [Console]::IsOutputRedirected;
$useColor = $interactive -and $Host.UI.SupportsVirtualTerminal -and -not $env:NO_COLOR;
$dashTop = 0;
$startLines = 0;
$oldEncoding = [Console]::OutputEncoding;
$esc = [char]27;
$c = @{};
$g = @{
	Fill = '#';
	Empty = '.';
	Rule = '-';
	Dot = '*';
	Check = '*';
}

foreach ($key in 'Reset', 'Bold', 'Dim', 'Pink', 'Orange', 'Cyan', 'Green', 'Yellow', 'Red', 'ClearLine') {
	$c[$key] = '';
}

if ($useColor) {
	$c = @{
		Reset = "$esc[0m";
		Bold = "$esc[1m";
		Dim = "$esc[90m";
		Pink = "$esc[38;2;255;102;170m";
		Orange = "$esc[38;2;255;153;51m";
		Cyan = "$esc[36m";
		Green = "$esc[92m";
		Yellow = "$esc[33m";
		Red = "$esc[31m";
		ClearLine = "$esc[K";
	}

	$g = @{
		Fill = [char]0x2501;
		Empty = [char]0x2500;
		Rule = [char]0x2500;
		Dot = [char]0x25CF;
		Check = [char]0x2714;
	}

	try {
		[Console]::OutputEncoding = [Text.Encoding]::UTF8;
	} catch {
	}
}

if ($interactive) {
	try {
		$lineCount = @(Get-DashboardLines).Count;
		$startLines = 1 + [Math]::Ceiling($startMessage.Length / [Math]::Max(1, [Console]::BufferWidth));
		[Console]::Write("`n" * $lineCount);
		$dashTop = [Math]::Max(0, [Console]::CursorTop - $lineCount);
		[Console]::CursorVisible = $false;
	} catch {
		$interactive = $false;
	}
}

$refreshSeconds = if ($interactive) {
	1;
}
else {
	30;
}

try {
	Show-Dashboard;
	$lastQueueDraw = Get-Date;

	foreach ($id in $ids) {
		$ps = [powershell]::Create().AddScript($worker).AddArgument($id).AddArgument($maps).AddArgument($n % $fast.Count).AddArgument($gapSeconds).AddArgument($fast).AddArgument($fallback).AddArgument($cooldowns).AddArgument($userAgent);
		$ps.RunspacePool = $pool;
		$jobs.Add([pscustomobject]@{
			Ps = $ps;
			Handle = $ps.BeginInvoke();
		});

		$n++;

		if (((Get-Date) - $lastQueueDraw).TotalMilliseconds -ge 500) {
			$phase = "preparing $n/$total";
			Show-Dashboard;
			$lastQueueDraw = Get-Date;
		}
	}

	$phase = 'running';
	$start = Get-Date;

	if ($interactive -and $startLines -gt 0) {
		$dashTop = [Math]::Max(0, $dashTop - $startLines);
		Show-Dashboard;
		[Console]::Write(((' ' * [Math]::Max(1, [Console]::BufferWidth - 1)) + "`n") * $startLines);
	}

	$lastReport = [datetime]::MinValue;
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

				if ($r.Mirror -ne 'existing') {
					if (-not $durBy[$r.Mirror]) {
						$durBy[$r.Mirror] = [System.Collections.Generic.Queue[double]]::new();
					}

					$durBy[$r.Mirror].Enqueue($r.Seconds);
					if ($durBy[$r.Mirror].Count -gt 50) {
						[void]$durBy[$r.Mirror].Dequeue();
					}
				}
			}
			else {
				$failed.Add($r.Id);
			}

			foreach ($e in $r.Errors) {
				$errBy[$e] = 1 + [int]$errBy[$e];
			}

			$log.WriteLine(("{0:s},{1},{2},{3},{4},{5}" -f (Get-Date), $r.Id, $r.Mirror, $r.Bytes, ($r.Errors -join ' '), $r.Seconds.ToString([cultureinfo]::InvariantCulture)));
		}

		if (((Get-Date) - $lastReport).TotalSeconds -ge $refreshSeconds) {
			Show-Dashboard;
			$lastReport = Get-Date;
		}

		Start-Sleep -Milliseconds 500;
	}
}
finally {
	if ($done -lt $total) {
		$phase = 'stopping...';
		Show-Dashboard;
	}

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

	Set-Content (Join-Path $out 'failed.txt') -Value @($failed);

	$phase = if ($done -ge $total) {
		'finished';
	}
	else {
		'stopped';
	}

	Show-Dashboard;

	if ($interactive) {
		try {
			[Console]::CursorVisible = $true;
			[Console]::OutputEncoding = $oldEncoding;
		} catch {
		}
	}

	Write-Host '';
	Write-Host ("  {0}Failed IDs are in failed.txt, every download is in download-log.csv{1}" -f $c.Dim, $c.Reset);
}