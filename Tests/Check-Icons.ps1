<#
.SYNOPSIS
    Checks of the shared icon conversion (ConvertTo-PngBytes in PackTune-Main.ps1) with real sample icons: a classic ICO with BMP frames,
    a Vista ICO with a 256 px PNG frame (System.Drawing cannot read it: the old "Ungueltiger Parameter"), an ICO with both (the largest
    frame wins), an .exe with an icon resource (as an MSI Icon table may hold one), and the paths that use the converter (MSI icon, MSIX
    logo, catalog custom icon, dialog preview). No network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Icons.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneIcons-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')
Add-Type -AssemblyName System.Drawing

function New-TestBitmap([int]$Size, [System.Drawing.Color]$Color) {
    $b = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear($Color); $g.FillEllipse([System.Drawing.Brushes]::White, 2, 2, $Size - 4, $Size - 4); $g.Dispose()
    $b
}
function Get-PngSize([byte[]]$Png) {
    $ms = New-Object IO.MemoryStream(, $Png); $img = [System.Drawing.Image]::FromStream($ms)
    try { "$($img.Width)x$($img.Height)" } finally { $img.Dispose(); $ms.Dispose() }
}
function Test-Png([byte[]]$B) { $B.Length -gt 8 -and $B[0] -eq 0x89 -and $B[1] -eq 0x50 -and $B[2] -eq 0x4E -and $B[3] -eq 0x47 }
function New-IcoBytes($Frames) {
    # Frames: @{ Size; Data; Bits }; the directory entry says 0 for 256
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$Frames.Count)
    $offset = 6 + 16 * $Frames.Count
    foreach ($f in $Frames) {
        $d = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]$f.Bits); $w.Write([uint32]$f.Data.Length); $w.Write([uint32]$offset)
        $offset += $f.Data.Length
    }
    foreach ($f in $Frames) { $w.Write([byte[]]$f.Data) }
    $w.Flush(); $ms.ToArray()
}
function Get-PngFrame([int]$Size, $Color) { $b = New-TestBitmap $Size $Color; $m = New-Object IO.MemoryStream; $b.Save($m, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); $m.ToArray() }
function Get-DibFrame([int]$Size, $Color) {
    # A classic ICO frame: BITMAPINFOHEADER (height doubled), 32 bit BGRA pixels bottom-up, AND mask
    $b = New-TestBitmap $Size $Color
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$Size); $w.Write([int32](2 * $Size)); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0); $w.Write([uint32]($Size * $Size * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $Size - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $Size; $x++) { $c = $b.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
    $maskRow = [int]([Math]::Ceiling($Size / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $Size)))
    $w.Flush(); $b.Dispose(); $ms.ToArray()
}

$workIcons = Join-Path $work 'icons'; New-Item -ItemType Directory -Path $workIcons -Force | Out-Null
$classic = New-IcoBytes @(@{ Size = 16; Data = (Get-DibFrame 16 ([System.Drawing.Color]::SteelBlue)); Bits = 32 }, @{ Size = 32; Data = (Get-DibFrame 32 ([System.Drawing.Color]::SteelBlue)); Bits = 32 })
$vista = New-IcoBytes @(@{ Size = 256; Data = (Get-PngFrame 256 ([System.Drawing.Color]::Firebrick)); Bits = 32 })
$mixed = New-IcoBytes @(@{ Size = 16; Data = (Get-DibFrame 16 ([System.Drawing.Color]::SeaGreen)); Bits = 32 }, @{ Size = 48; Data = (Get-DibFrame 48 ([System.Drawing.Color]::SeaGreen)); Bits = 32 }, @{ Size = 256; Data = (Get-PngFrame 256 ([System.Drawing.Color]::SeaGreen)); Bits = 32 })

$png = ConvertTo-PngBytes -Bytes $classic -WorkPath $workIcons
Test-Check 'classic ICO with BMP frames: PNG of the largest frame (32x32)' ((Test-Png $png) -and (Get-PngSize $png) -eq '32x32') "$(Get-PngSize $png)"
$px = New-Object IO.MemoryStream(, $png); $bmp = [System.Drawing.Bitmap][System.Drawing.Image]::FromStream($px)
Test-Check 'classic ICO: the picture is the one of the icon (colour and transparency kept)' (($bmp.GetPixel(16, 16).R -eq 255) -and ($bmp.GetPixel(0, 0).R -eq 70) -and ($bmp.GetPixel(0, 0).B -eq 180))
$bmp.Dispose()
$png = ConvertTo-PngBytes -Bytes $vista -WorkPath $workIcons
Test-Check 'Vista ICO with a PNG-256 frame: the frame bytes are used directly (256x256)' ((Test-Png $png) -and (Get-PngSize $png) -eq '256x256' -and $png.Length -eq ($vista.Length - 22))
$png = ConvertTo-PngBytes -Bytes $mixed -WorkPath $workIcons
Test-Check 'ICO with 16, 48 and 256 frames: the largest wins' ((Test-Png $png) -and (Get-PngSize $png) -eq '256x256')
$noPng = New-IcoBytes @(@{ Size = 16; Data = (Get-DibFrame 16 ([System.Drawing.Color]::SeaGreen)); Bits = 32 }, @{ Size = 48; Data = (Get-DibFrame 48 ([System.Drawing.Color]::SeaGreen)); Bits = 32 })
Test-Check 'ICO with 16 and 48 BMP frames: 48x48' ((Get-PngSize (ConvertTo-PngBytes -Bytes $noPng -WorkPath $workIcons)) -eq '48x48')
Test-Check 'PNG, JPEG and a plain BMP still convert as before' ((Test-Png (ConvertTo-PngBytes -Bytes (Get-PngFrame 64 ([System.Drawing.Color]::Gray)) -WorkPath $workIcons)) -and ((Get-PngSize (ConvertTo-PngBytes -Bytes ([IO.File]::ReadAllBytes((& { $f = Join-Path $workIcons 'p.bmp'; $b = New-TestBitmap 24 ([System.Drawing.Color]::Gray); $b.Save($f, [System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose(); $f }))) -WorkPath $workIcons)) -eq '24x24'))
$threw = $false; try { $null = ConvertTo-PngBytes -Bytes ([byte[]](1..50)) -WorkPath $workIcons } catch { $threw = $true }
Test-Check 'garbage is refused with an error (the caller then continues without an icon)' $threw

# an EXE with an icon resource: what an MSI Icon table often holds
$icoFile = Join-Path $workIcons 'stub.ico'; [IO.File]::WriteAllBytes($icoFile, $classic)
$exe = Join-Path $workIcons 'icon-stub.exe'
$cp = New-Object System.CodeDom.Compiler.CompilerParameters; $cp.GenerateExecutable = $true; $cp.OutputAssembly = $exe; $cp.CompilerOptions = "/win32icon:`"$icoFile`""
$prov = New-Object Microsoft.CSharp.CSharpCodeProvider
$res = $prov.CompileAssemblyFromSource($cp, 'public static class P { public static void Main() { } }')
Test-Check 'sample: an exe stub with the icon resource was compiled' ((Test-Path $exe) -and $res.Errors.Count -eq 0) ($res.Errors | Out-String)
$png = ConvertTo-PngBytes -Bytes ([IO.File]::ReadAllBytes($exe)) -WorkPath $workIcons
Test-Check 'EXE icon (MSI Icon table holding an EXE): extracted from the resource, largest frame, PNG' ((Test-Png $png) -and (Get-PngSize $png) -eq '32x32') "$(Get-PngSize $png)"
Test-Check 'EXE icon: nothing is left behind and the exe was only read' (@(Get-ChildItem $workIcons -Filter 'icon-source-*').Count -eq 0)
$plainExe = Join-Path $workIcons 'noicon.exe'
$cp2 = New-Object System.CodeDom.Compiler.CompilerParameters; $cp2.GenerateExecutable = $true; $cp2.OutputAssembly = $plainExe
$null = $prov.CompileAssemblyFromSource($cp2, 'public static class P { public static void Main() { } }')
$threw = $false; try { $null = ConvertTo-PngBytes -Bytes ([IO.File]::ReadAllBytes($plainExe)) -WorkPath $workIcons } catch { $threw = $_.Exception.Message -like '*no icon*' }
Test-Check 'an exe without an icon resource is refused clearly' $threw

# Get-ChocoIconBase64 (catalog custom icon, MSI icon, MSIX logo all go through it)
$vistaFile = Join-Path $workIcons 'vista.ico'; [IO.File]::WriteAllBytes($vistaFile, $vista)
$b64 = Get-ChocoIconBase64 -ChocoName 'icon-check' -IconFile $vistaFile -NoIconPrompt -NoFeedLookup
Test-Check 'Get-ChocoIconBase64 with the Vista icon returns the PNG (no more "Icon could not be converted")' ($b64 -and (Test-Png ([Convert]::FromBase64String($b64))) -and (Get-PngSize ([Convert]::FromBase64String($b64))) -eq '256x256')
$b64e = Get-ChocoIconBase64 -ChocoName 'icon-check' -IconFile $exe -NoIconPrompt -NoFeedLookup
Test-Check 'Get-ChocoIconBase64 with an exe takes its icon' ($b64e -and (Get-PngSize ([Convert]::FromBase64String($b64e))) -eq '32x32')
# an MSI whose Icon table holds the Vista icon (and the ARPPRODUCTICON property): the extraction helper and the upload path
function New-IconMsi([string]$Path, [string]$IconName, [byte[]]$IconBytes) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 3))
    foreach ($sql in 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(255) NOT NULL PRIMARY KEY `Property`)', 'CREATE TABLE `Icon` (`Name` CHAR(72) NOT NULL, `Data` OBJECT NOT NULL PRIMARY KEY `Name`)') {
        $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql)); [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null); [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    }
    foreach ($kv in @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000001}'; ProductName = 'Icon Tool'; ProductVersion = '1.0.0'; Manufacturer = 'Icon Ltd'; ARPPRODUCTICON = $IconName }.GetEnumerator()) {
        $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('$($kv.Key)', '$($kv.Value)')")); [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null); [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    }
    $tmp = Join-Path (Split-Path $Path) ($IconName); [IO.File]::WriteAllBytes($tmp, $IconBytes)
    $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("INSERT INTO `Icon` (`Name`, `Data`) VALUES (?, ?)"))
    $rec = $installer.GetType().InvokeMember('CreateRecord', 'InvokeMethod', $null, $installer, @(2))
    $rec.GetType().InvokeMember('StringData', 'SetProperty', $null, $rec, @(1, $IconName))
    [void]$rec.GetType().InvokeMember('SetStream', 'InvokeMethod', $null, $rec, @(2, [string]$tmp))
    [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, @($rec)); [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
    foreach ($o in $rec, $v, $db, $installer) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
$msiPath = Join-Path $workIcons 'icon-tool.msi'
$msiOk = $true; try { New-IconMsi $msiPath 'ProductIcon.ico' $vista } catch { $msiOk = $false; $msiErr = $_.Exception.Message }
if ($msiOk) {
    $info = Get-PackTuneMsiInfo -Path $msiPath
    $extracted = Save-PackTuneMsiIcon -Path $msiPath -IconName $info.IconName -Destination (Join-Path $workIcons 'from-msi.bin')
    Test-Check 'MSI: the icon of the Icon table (ARPPRODUCTICON) is extracted byte for byte' ($extracted -and (Compare-Object ([IO.File]::ReadAllBytes($extracted)) $vista).Count -eq 0)
    $icon = Get-PackTuneMsiIconBase64 -Info $info
    Test-Check 'MSI: the upload icon is the PNG of the icon (the app is created WITH its icon)' ($icon -and (Test-Png ([Convert]::FromBase64String($icon))) -and (Get-PngSize ([Convert]::FromBase64String($icon))) -eq '256x256')
}
else { Test-Check 'MSI with an Icon table could be made' $false $msiErr }

# the dialog preview uses the same converter as the upload
$gui = Get-Content (Join-Path $repo 'Start-PackTune.ps1') -Raw
Test-Check 'preview: the dialog converts the MSI and EXE icon with ConvertTo-PngBytes, like the upload' ($gui -match 'msi-icon\.png' -and $gui -match "ConvertTo-PngBytes -Bytes \(\[IO\.File\]::ReadAllBytes\(\`$raw\)\)" -and $gui -match "ConvertTo-PngBytes -Bytes \(\[IO\.File\]::ReadAllBytes\(\`$exe\)\)")

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
