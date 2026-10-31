# 把 TVBox 配置里的相对路径改写成绝对 URL（影视仓必须用绝对 URL，不支持相对路径）
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

# 单个字符串 -> 绝对 URL
# $withParams = $true 时，形如 "./lib/token.json$$$参数1$$$参数2"：
#   只有第 1 段是文件路径，$$$ 之后是 App 自己解析的参数，必须原样保留（不能编码）
function Abs-Scalar([object]$v, [bool]$withParams) {
    if ($null -eq $v) { return $v }
    $s = [string]$v
    if ($s -match '^(https?|file|assets|proxy)://') { return $s }
    if ($s.StartsWith('./') -or $s.StartsWith('../')) {
        if ($withParams) {
            $parts = $s -split '(\$\$\$)'
            $parts[0] = $Base + (Enc-Path ($parts[0] -replace '^\.\./', '' -replace '^\./', ''))
            return ($parts -join '')
        }
        return $Base + (Enc-Path ($s -replace '^\.\./', '' -replace '^\./', ''))
    }
    return $s
}

# 递归重写：字符串 -> 绝对化；对象/数组 -> 保持原有结构，只改里面的字符串
# （ext 常常是 {"token":"...","filter":"./json/x.json"} 这种对象，不能当成字符串处理）
function Rewrite([object]$v, [bool]$withParams) {
    if ($null -eq $v) { return $null }
    if ($v -is [string]) { return (Abs-Scalar $v $withParams) }
    if ($v -is [System.ValueType]) { return $v }
    if ($v -is [System.Collections.IDictionary]) {
        foreach ($k in @($v.Keys)) { $v[$k] = (Rewrite $v[$k] $withParams) }
        return $v
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $v) { $v[$i] = (Rewrite $item $withParams); $i++ }
        return $v
    }
    foreach ($p in $v.PSObject.Properties) {
        if ($p.IsReadOnly) { continue }
        try { $p.Value = (Rewrite $p.Value $withParams) } catch { }
    }
    return $v
}

# 递归找出仍然以 "./" 开头的字符串（用于校验）
function Find-Relative([object]$v, [System.Collections.ArrayList]$acc) {
    if ($null -eq $v) { return }
    if ($v -is [string]) {
        if ($v.StartsWith('./') -or $v.StartsWith('../')) { [void]$acc.Add($v) }
        return
    }
    if ($v -is [System.ValueType]) { return }
    if ($v -is [System.Collections.IDictionary]) {
        foreach ($k in @($v.Keys)) { Find-Relative $v[$k] $acc }
        return
    }
    if ($v -is [System.Collections.IEnumerable]) {
        foreach ($item in $v) { Find-Relative $item $acc }
        return
    }
    foreach ($p in $v.PSObject.Properties) { Find-Relative $p.Value $acc }
}

$j = Get-Content -LiteralPath $Source -Raw -Encoding UTF8 | ConvertFrom-Json

# 1) spider: "./jar/x.jar;md5;hash"  ->  绝对URL;md5;hash
if ($j.spider) {
    $parts = ([string]$j.spider) -split ';md5;', 2
    $j.spider = (Abs-Scalar $parts[0] $false)
    if ($parts.Count -gt 1) { $j.spider = $j.spider + ';md5;' + $parts[1] }
}

# 2) sites[].api / sites[].ext（ext 可能是字符串，也可能是对象，都按原结构重写）
foreach ($s in $j.sites) {
    if ($s.api) { $s.api = (Rewrite $s.api $true) }
    if ($s.ext) { $s.ext = (Rewrite $s.ext $true) }
}

# 3) lives[].url（相对路径在影视仓里会解析成空列表，必须绝对）
if ($j.lives) {
    foreach ($l in $j.lives) { if ($l.url) { $l.url = (Abs-Scalar $l.url $false) } }
}

# 4) parses[].url
if ($j.parses) {
    foreach ($p in $j.parses) { if ($p.url) { $p.url = (Abs-Scalar $p.url $false) } }
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
            url        = (Abs-Scalar $parts[1] $false)
            playerType = 1
            ua         = 'okhttp/3.15'
        }
    }
    if ($j.PSObject.Properties.Name -contains 'lives') {
        $j.lives = $newLives
    } else {
        $j | Add-Member -NotePropertyName 'lives' -NotePropertyValue $newLives -Force
    }
}

# 无 BOM 输出，否则影视仓解析 JSON 会失败
[System.IO.File]::WriteAllText($Out, ($j | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

# 校验 1：不应再有相对路径（全树递归）
$check = Get-Content -LiteralPath $Out -Raw -Encoding UTF8 | ConvertFrom-Json
$bad = New-Object System.Collections.ArrayList
Find-Relative $check $bad
if ($bad.Count -gt 0) {
    Write-Host ("  [警告] 仍有 {0} 处相对路径，例如: {1}" -f $bad.Count, $bad[0])
} else {
    Write-Host '  [校验] 全部已转为绝对 URL'
}

# 校验 2：ext 对象不能被压成字符串
$broken = 0
foreach ($s in $check.sites) {
    if ($s.ext -is [string] -and $s.ext -match '^[@\{]') { $broken++ }
}
if ($broken -gt 0) {
    Write-Host ("  [警告] {0} 个站点的 ext 被序列化成字符串，必须修复" -f $broken)
} else {
    Write-Host '  [校验] ext 结构完好'
}

# 校验 3：无 BOM
$bytes = [System.IO.File]::ReadAllBytes($Out)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host '  [警告] 输出文件带 BOM，影视仓会解析失败'
} else {
    Write-Host '  [校验] 无 BOM'
}
