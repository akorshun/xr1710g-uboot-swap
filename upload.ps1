#Requires -Version 5.1
<#
.SYNOPSIS
  XR1710G: upload an image into the http-uboot HTTP recovery from a Windows PC.
.DESCRIPTION
  Run it when the router is already in recovery (http://192.168.255.1).
  By default it uploads the http-uboot bootloader (target uboot).
  Messages are in English or Russian: -Lang en|ru, $env:XR1710G_LANG,
  or a question at start-up.
.EXAMPLE
  .\upload.ps1
.EXAMPLE
  .\upload.ps1 -Target firmware -Layout 2.0 -File .\openwrt-xr1710g-sysupgrade.itb -Lang en
#>
param(
    [string]$Address = "192.168.255.1",
    [ValidateSet("uboot", "firmware")][string]$Target = "uboot",
    [ValidateSet("2.0", "1.5", "1.0")][string]$Layout = "2.0",
    [string]$File = "",
    [int]$WaitSeconds = 180,
    [string]$Lang = "",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptVersion = "1.1"
$SlotImage = "xr1710g-chainloader-slot.bin"
$SlotSha256 = "DEAEFED37C13F25EB551D60951CEC7077ADFD01C6964174D0AA938288D27BE30"
$SlotUrl = "https://github.com/akorshun/xr1710g-uboot-swap/raw/main/firmware/xr1710g-chainloader-slot.bin"
$SlotMax = 1048576

# --- language ---------------------------------------------------------------
if ($Lang -eq "" -and $env:XR1710G_LANG) { $Lang = $env:XR1710G_LANG }
if ($Lang -ne "en" -and $Lang -ne "ru") {
    $guess = "en"
    if ((Get-Culture).Name -like "ru*") { $guess = "ru" }
    if ($Yes) {
        $Lang = $guess
    } else {
        $default = "1"
        if ($guess -eq "ru") { $default = "2" }
        Write-Host "Language / Язык:"
        Write-Host "  1) English"
        Write-Host "  2) Русский"
        $choice = Read-Host "[$default]"
        if ($choice -eq "") { $choice = $default }
        if ($choice -match '^(2|ru)$') { $Lang = "ru" } else { $Lang = "en" }
    }
}

# T <russian> <english>: the message in the selected language.
function T($ru, $en) {
    if ($Lang -eq "ru") { return $ru }
    return $en
}

function Write-Fail($message) {
    Write-Host "$(T 'ОШИБКА' 'ERROR'): $message" -ForegroundColor Red
    exit 1
}

function Write-Warn($message) {
    Write-Host "$(T 'ВНИМАНИЕ' 'WARNING'): $message" -ForegroundColor Yellow
}

function Confirm-Step($message) {
    if ($Yes) { return }
    $answer = Read-Host "$message [y/N]"
    if ($answer -notmatch '^(y|yes|да)$') { Write-Fail (T "отменено пользователем" "cancelled by the user") }
}

function Get-Json($url, $timeout) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeout
        return ($response.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

Write-Host "=== $(T 'XR1710G: заливка в HTTP-рекавери' 'XR1710G: upload into the HTTP recovery') (upload.ps1 $ScriptVersion) ==="

# --- image ------------------------------------------------------------------
$temp = $null
if ($File -eq "") {
    if ($Target -ne "uboot") { Write-Fail (T "для цели firmware укажите образ через -File" "for the firmware target pass the image with -File") }
    $local = Join-Path (Join-Path $PSScriptRoot "firmware") $SlotImage
    if (Test-Path -LiteralPath $local) {
        $File = $local
    } else {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) $SlotImage
        Write-Host (T "Скачиваю $SlotImage ..." "Downloading $SlotImage ...")
        Invoke-WebRequest -Uri $SlotUrl -OutFile $temp -UseBasicParsing
        $File = $temp
    }
}
if (-not (Test-Path -LiteralPath $File)) { Write-Fail (T "файл $File не найден" "file $File not found") }

$item = Get-Item -LiteralPath $File
$size = $item.Length
$hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
Write-Host "$(T 'Образ:                ' 'Image:                ') $($item.FullName)"
Write-Host "$(T '  размер:             ' '  size:               ') $size $(T 'байт' 'bytes')"
Write-Host "  sha256:              $hash"

if ($Target -eq "uboot") {
    if ($size -gt $SlotMax) {
        Write-Fail (T "образ загрузчика больше 1 МиБ, рекавери его отвергнет" "the bootloader image is larger than 1 MiB, the recovery will reject it")
    }
    $head = [System.IO.File]::ReadAllBytes($File)[0..3]
    $magic = ($head | ForEach-Object { $_.ToString("x2") }) -join ""
    if ($magic -ne "27051956") {
        Write-Fail (T "это не образ слота: нет legacy-заголовка uImage (magic $magic). Нужен $SlotImage, а не u-boot.bin или *.itb" `
            "this is not a slot image: no legacy uImage header (magic $magic). Use $SlotImage, not u-boot.bin or *.itb")
    }
    if ($hash -eq $SlotSha256) {
        Write-Host "$(T '  проверка:           ' '  check:              ') $(T 'совпадает с xr1710g_260805 из YYH2913/http-uboot' 'matches xr1710g_260805 from YYH2913/http-uboot')"
    } else {
        Write-Warn (T "образ не совпадает с известным xr1710g_260805, убедитесь в его происхождении" "the image does not match the known xr1710g_260805, make sure where it comes from")
    }
} else {
    if ($size -lt 1048576) {
        Write-Fail (T "образ прошивки меньше 1 МиБ, это не sysupgrade.itb" "the firmware image is smaller than 1 MiB, this is not a sysupgrade.itb")
    }
    Write-Host "$(T '  раскладка UBI:      ' '  UBI layout:         ') $Layout $(T '(должна совпадать с DTS образа!)' '(must match the DTS of the image!)')"
}

# --- waiting for the recovery -----------------------------------------------
Write-Host ""
Write-Host "$(T 'Жду рекавери на' 'Waiting for the recovery at') http://$Address" -NoNewline
$about = $null
$waited = 0
while ($waited -lt $WaitSeconds) {
    $about = Get-Json "http://$Address/about" 3
    if ($about -ne $null) { break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 2
    $waited += 2
}
Write-Host ""
if ($about -eq $null) {
    $ru = @"
рекавери не ответило за $WaitSeconds с.
       Проверьте: ПК в порту 10GbE, адрес получен по DHCP (192.168.255.2),
       роутер в рекавери (кнопка reset при включении или flash.sh на роутере)
"@
    $en = @"
the recovery did not answer within $WaitSeconds s.
       Check: PC on the 10GbE port, address from DHCP (192.168.255.2),
       router in recovery (reset at power-on, or flash.sh on the router)
"@
    Write-Fail (T $ru $en)
}

if ($about.u_boot) { Write-Host "$(T 'Рекавери:             ' 'Recovery:             ') $($about.u_boot)" }
if ($about.detected_layout) { Write-Host "$(T 'Текущая раскладка:    ' 'Current layout:       ') $($about.detected_layout)" }
$uiBuild = ""
if ($about.ui_build) {
    $uiBuild = $about.ui_build
    Write-Host "UI build:              $uiBuild"
}

# --- confirmation -----------------------------------------------------------
if ($Target -eq "uboot") {
    Confirm-Step (T "Записать этот образ в слот загрузчика (1 МиБ) на $Address?" "Write this image into the bootloader slot (1 MiB) on $Address?")
} else {
    Confirm-Step (T "Перезаписать UBI ($Layout) прошивкой на $Address? Данные будут стёрты!" "Overwrite UBI ($Layout) with the firmware on $Address? Data will be erased!")
}

# --- upload -----------------------------------------------------------------
$url = "http://$Address/upload/$Target"
$sep = "?"
if ($uiBuild -ne "") {
    $url = "$url$sep" + "ui_build=" + [System.Uri]::EscapeDataString($uiBuild)
    $sep = "&"
}
if ($Target -eq "firmware") {
    $url = "$url$sep" + "layout=" + [System.Uri]::EscapeDataString($Layout)
}

Write-Host ""
Write-Host "POST $url"
try {
    $post = Invoke-WebRequest -Uri $url -Method Post -InFile $File `
        -ContentType "application/octet-stream" -UseBasicParsing -TimeoutSec 600
    Write-Host "$(T 'Образ принят рекавери' 'The recovery accepted the image') (HTTP $($post.StatusCode))."
} catch {
    Write-Fail (T "POST не удался: $($_.Exception.Message). Состояние смотрите на http://$Address" `
        "POST failed: $($_.Exception.Message). Check the state at http://$Address")
}

# --- progress ---------------------------------------------------------------
Write-Host ""
Write-Host (T "Ход операции:" "Progress:")
$last = ""
$generation = 0
for ($i = 0; $i -lt 300; $i++) {
    $st = Get-Json "http://$Address/status" 5
    if ($st -eq $null) { Start-Sleep -Seconds 2; continue }
    $line = "  $(T 'стирание' 'erase') $($st.erase_done)/$($st.erase_total), $(T 'запись' 'write') $($st.write_done)/$($st.write_total)"
    if ($line -ne $last) {
        Write-Host $line
        $last = $line
    }
    if ($st.error -ne 0) {
        Write-Fail "$(T 'рекавери вернуло ошибку' 'the recovery returned an error') (code $($st.error), stage '$($st.error_stage)', detail '$($st.validation_detail)')"
    }
    if ($st.ok -eq 1 -and $st.in_progress -eq 0) {
        if ($st.completion_generation) { $generation = $st.completion_generation }
        Write-Host "  $(T 'готово' 'done')"
        break
    }
    Start-Sleep -Seconds 2
}

if ($generation -gt 0) {
    Get-Json "http://$Address/status-ack/$generation" 5 | Out-Null
    Write-Host (T "Подтверждение отправлено, роутер перезагружается." "Acknowledgement sent, the router is rebooting.")
} else {
    Write-Host (T "Роутер перезагрузится сам." "The router reboots by itself.")
}

if ($temp -ne $null -and (Test-Path -LiteralPath $temp)) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
