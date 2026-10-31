# 把 TVBox 配置里的相对路径改写成绝对 URL（影视仓必须用绝对 URL）
# 用法: powershell -File build-config.ps1 -Source <源json> -Base <绝对基地址> -Out <输出json>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Out,
    [string[]]$Lives,
    [string]$LiveSpec   # 命令行传参用："名称|路径;名称|路径"
)
$ErrorActionPreference = 'Stop'
$Base = $Base.TrimEnd('/') + '/'

function Enc-Path([string]$rel) {
    # 路径分段百分号编码（中文文件名必须编码，否则 App 拉不到）
    (($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

# 形如 "./lib/token.json$$$参数1$$$参数2"：只有第 1 段是文件路径，
# $$$ 之后是 App 自己解析的参数，必须原样保留（不能编码）
function Abs-WithParams([object]$v) {
    if ($null -eq $v) { return $v }
    $s = [string]$v
    if ($s -match '^(https?|file|assets|proxy)://') { return $s }
    if ($s.StartsWith('./') -or $s.StartsWith('../')) {
        $parts = $s -split '(\$\$\$)'
        $parts[0] = $Base + (Enc-Path ($parts[0] -replace '^\.\./', '' -replace '^\./', ''))
        return ($parts -join '')
    }
    return $s
}

function Abs([object]$v) {
    if ($null -eq $v) { return $v }
    $s = [string]$v
    if ($s -match '^(https?|file|assets|proxy)://') { return $s }
    if ($s.StartsWith('./') -or $s.StartsWith('../')) { return $Base + (Enc-Path ($s -replace '^\.\./', '' -replace '^\./', '')) }
    return $s
}

$j = Get-Content -LiteralPath $Source -Raw -Encoding UTF8 | ConvertFrom-Json

# 1) spider: "./jar/x.jar;md5;hash"  ->  绝对URL;md5;hash
if ($j.spider) {
    $parts = ([string]$j.spider) -split ';md5;', 2
    $j.spider = (Abs $parts[0])
    if ($parts.Count -gt 1) { $j.spider = $j.spider + ';md5;' + $parts[1] }
}

# 2) sites[].api / sites[].ext（ext 可能带 $$$参数，需分段处理）
foreach ($s in $j.sites) {
    if ($s.api) { $s.api = (Abs-WithParams $s.api) }
    if ($s.ext) { $s.ext = (Abs-WithParams $s.ext) }
}

# 3) lives[].url（相对路径在影视仓里会解析成空列表，必须绝对）
if ($j.lives) {
    foreach ($l in $j.lives) { if ($l.url) { $l.url = (Abs $l.url) } }
}

# 4) parses[].url
if ($j.parses) {
    foreach ($p in $j.parses) { if ($p.url) { $p.url = (Abs $p.url) } }
}

# 5) 可选：覆盖 lives 组（直播源地址）
# LiveSpec 形如 "名称|路径;名称|路径"；-Lives 为数组（进程内调用）
$liveList = @()
if ($Lives -and $Lives.Count -gt 0) { $liveList = @($Lives) }
elseif ($LiveSpec) { $liveList = @($LiveSpec -split ';' | Where-Object { $_.Trim() }) }
if ($liveList.Count -gt 0) {
    $newLives = @()
    foreach ($lv in $liveList) {
        $parts = ([string]$lv) -split '\|', 2
        $newLives += [pscustomobject]@{
            name       = $parts[0]
            type       = 0
            url        = (Abs $parts[1])
            playerType = 1
            ua         = 'okhttp/3.15'
        }
    }
    # 有些备用仓原本没有 lives 字段，需先补属性再赋值
    if ($j.PSObject.Properties.Name -contains 'lives') {
        $j.lives = $newLives
    } else {
        $j | Add-Member -NotePropertyName 'lives' -NotePropertyValue $newLives -Force
    }
}

# 无 BOM 输出，否则影视仓解析 JSON 会失败
[System.IO.File]::WriteAllText($Out, ($j | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

# 校验：不应再有相对路径
$check = Get-Content -LiteralPath $Out -Raw -Encoding UTF8 | ConvertFrom-Json
$bad = @()
if (([string]$check.spider) -match '^(?!\w+://)\S') { $bad += 'spider' }
foreach ($s in $check.sites) { if (([string]$s.api) -match '^\./') { $bad += "site.api" ; break } }
foreach ($l in $check.lives) { if (([string]$l.url) -match '^\./') { $bad += 'live.url'; break } }
if ($bad.Count -gt 0) { Write-Host ("  [警告] 仍有相对路径: {0}" -f ($bad -join ', ')) }
else { Write-Host '  [校验] 全部已转为绝对 URL ✓' }
