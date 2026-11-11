# Импорт заказов WB -> МойСклад: запуск на своём ПК.
# Скачивает свежую страницу с GitHub Pages, отдаёт её на http://localhost:8787/
# и проксирует запросы /api/ms напрямую в api.moysklad.ru (без Cloudflare и прочих
# зарубежных площадок, которые режут провайдеры). Токен никуда не сохраняется.
# Запуск: двойной клик по wb-moysklad.bat (или: powershell -ExecutionPolicy Bypass -File этот_файл).

param(
  [int]$Port = 8787,
  [string]$Site = 'https://homeresurs.github.io/wb-moysklad/',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$MsBase = 'https://api.moysklad.ru/api/remap/1.2'
$AllowedPrefixes = @('/entity/', '/context/', '/report/', '/security/token')
$PassHeaders = @('x-lognex-retry-after', 'x-ratelimit-remaining', 'x-lognex-retry-timeinterval')
$Files = @('index.html', 'vendor/xlsx.full.min.js')
$Dir = Join-Path $env:LOCALAPPDATA 'wb-moysklad'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

function Update-SiteFiles {
  New-Item -ItemType Directory -Force (Join-Path $Dir 'vendor') | Out-Null
  foreach ($f in $Files) {
    $target = Join-Path $Dir $f
    try {
      Invoke-WebRequest -Uri ($Site + $f) -OutFile $target -UseBasicParsing -TimeoutSec 30 | Out-Null
      Write-Log "Обновлён $f"
    } catch {
      if (Test-Path $target) { Write-Log "Не удалось обновить $f, использую сохранённую копию" }
      else { throw "Не удалось скачать $Site$f и нет сохранённой копии: $($_.Exception.Message)" }
    }
  }
}

function Send-Bytes($ctx, [int]$status, [string]$contentType, [byte[]]$bytes, $extra) {
  $res = $ctx.Response
  $res.StatusCode = $status
  $res.ContentType = $contentType
  $res.Headers['Cache-Control'] = 'no-store'
  if ($extra) { foreach ($k in $extra.Keys) { $res.Headers[$k] = [string]$extra[$k] } }
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function Send-Json($ctx, [int]$status, [string]$json, $extra) {
  Send-Bytes $ctx $status 'application/json; charset=utf-8' $Utf8.GetBytes($json) $extra
}

function Send-ProxyError($ctx, [int]$status, [string]$message) {
  $body = @{ errors = @(@{ error = $message; proxy = $true }) } | ConvertTo-Json -Compress -Depth 4
  Send-Json $ctx $status $body $null
}

function Send-File($ctx, [string]$name, [string]$contentType) {
  $path = Join-Path $Dir $name
  if (-not (Test-Path $path)) { Send-ProxyError $ctx 404 "Файл не найден: $name"; return }
  Send-Bytes $ctx 200 $contentType ([IO.File]::ReadAllBytes($path)) $null
}

function Invoke-MsProxy($ctx) {
  $req = $ctx.Request
  if ($req.QueryString['ping'] -ne $null) {
    Send-Json $ctx 200 ('{"ok":true,"proxy":"local","host":"' + $env:COMPUTERNAME + '"}') $null
    return
  }
  $method = $req.HttpMethod.ToUpperInvariant()
  if (@('GET', 'POST', 'PUT') -notcontains $method) { Send-ProxyError $ctx 405 "Метод не поддерживается: $method"; return }

  $path = [string]$req.QueryString['path']
  if (-not $path -or $path[0] -ne '/') { Send-ProxyError $ctx 400 'Не указан путь запроса (path).'; return }
  if ($path.Contains('..') -or $path.Contains('://') -or $path.Contains('\')) { Send-ProxyError $ctx 400 'Недопустимый путь запроса.'; return }
  $allowed = $false
  foreach ($p in $AllowedPrefixes) { if ($path.StartsWith($p)) { $allowed = $true } }
  if (-not $allowed) { Send-ProxyError $ctx 403 'Этот раздел API через прокси недоступен.'; return }

  $auth = $req.Headers['X-Ms-Authorization']
  if (-not $auth) { $auth = $req.Headers['Authorization'] }
  if (-not $auth) { Send-ProxyError $ctx 401 'Не передан токен или логин/пароль МойСклад.'; return }
  if ($auth -notmatch '^(Bearer|Basic) [A-Za-z0-9+/=._\-]+$') { Send-ProxyError $ctx 400 'Неверный формат авторизации.'; return }

  $up = [Net.HttpWebRequest]::Create($MsBase + $path)
  $up.Method = $method
  $up.Timeout = 55000
  $up.AutomaticDecompression = [Net.DecompressionMethods]::GZip
  $up.Accept = 'application/json;charset=utf-8'
  $up.UserAgent = 'wb-moysklad-local/2.1'
  $up.Headers['Authorization'] = $auth
  $up.AllowAutoRedirect = $false
  if ($method -ne 'GET') {
    # Пересылаем тело байтами как есть: без charset в Content-Type .NET взял бы cp1251 и испортил кириллицу.
    $buf = New-Object IO.MemoryStream; $req.InputStream.CopyTo($buf); $req.InputStream.Close()
    $bodyBytes = $buf.ToArray()
    $up.ContentType = 'application/json'
    $up.ContentLength = $bodyBytes.Length
    if ($bodyBytes.Length -gt 0) { $s = $up.GetRequestStream(); $s.Write($bodyBytes, 0, $bodyBytes.Length); $s.Close() }
  }

  $resp = $null
  try { $resp = $up.GetResponse() }
  catch [Net.WebException] {
    if ($_.Exception.Response) { $resp = $_.Exception.Response }
    else { Send-ProxyError $ctx 502 ('Сервер не смог связаться с МойСклад: ' + $_.Exception.Message); return }
  }
  $stream = $resp.GetResponseStream()
  $ms = New-Object IO.MemoryStream; $stream.CopyTo($ms); $stream.Close()
  $ct = $resp.ContentType; if (-not $ct) { $ct = 'application/json; charset=utf-8' }
  $extra = @{}
  foreach ($h in $PassHeaders) { $v = $resp.Headers[$h]; if ($v) { $extra[$h] = $v } }
  $status = [int]$resp.StatusCode
  $resp.Close()
  Send-Bytes $ctx $status $ct $ms.ToArray() $extra
}

Write-Host '=== Импорт заказов WB -> МойСклад: локальный запуск ==='
Update-SiteFiles

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { throw "Порт $Port занят или нет прав. Закройте другое окно этого скрипта или запустите с другим портом: -Port 8788. ($($_.Exception.Message))" }
$url = "http://localhost:$Port/"
Write-Log "Готово. Откройте в браузере: $url  (это окно не закрывайте, Ctrl+C — остановить)"
if (-not $NoBrowser) { Start-Process $url }

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $p = $ctx.Request.Url.AbsolutePath
    switch -Regex ($p) {
      '^/(index\.html)?$'            { Send-File $ctx 'index.html' 'text/html; charset=utf-8' }
      '^/vendor/xlsx\.full\.min\.js$' { Send-File $ctx 'vendor/xlsx.full.min.js' 'application/javascript' }
      '^/api/ms/?$'                  { Invoke-MsProxy $ctx }
      default                        { Send-ProxyError $ctx 404 "Нет такого адреса: $p" }
    }
  } catch {
    Write-Log "Ошибка: $($_.Exception.Message)"
    try { Send-ProxyError $ctx 500 ('Ошибка локального прокси: ' + $_.Exception.Message) } catch {}
  }
}
