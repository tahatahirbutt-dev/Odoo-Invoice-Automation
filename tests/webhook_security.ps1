<#
  Live test of the PDF webhook's access control. Needs the stack running and a real invoice id.
  Run from anywhere:   .\tests\webhook_security.ps1                      (local n8n, invoice id 1)
                       .\tests\webhook_security.ps1 -BaseUrl https://hooks.example.com -InvoiceId 12
  Reads PDF_LINK_SECRET from ../.env and never prints it. Exit code 1 if any case fails.
  It asserts Content-Type, not just the status code: an Odoo login page comes back as 200 text/html.
#>
param(
  [string]$BaseUrl   = "http://localhost:5678",
  [int]   $InvoiceId = 1
)

$envFile = Join-Path $PSScriptRoot "..\.env"
$line = Get-Content $envFile | Where-Object { $_ -match '^PDF_LINK_SECRET=' } | Select-Object -First 1
if (-not $line) { Write-Host "PDF_LINK_SECRET not found in .env"; exit 1 }
$secret = ($line -replace '^PDF_LINK_SECRET=', '').Trim()
if ($secret -notmatch '^[0-9a-f]{64}$') { Write-Host "PDF_LINK_SECRET must be 64 hex characters"; exit 1 }

function Get-Token([string]$payload) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = [Text.Encoding]::UTF8.GetBytes($secret)
  ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
function Get-Result([string]$url) {
  $out = curl.exe -s -o NUL -w "%{http_code}|%{content_type}" $url
  $code, $type = $out -split '\|', 2
  @{ Code = $code; Type = $type }
}

$base = "$BaseUrl/webhook/invoice-pdf"
$now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$exp  = $now + 600
$old  = $now - 60
$tok  = Get-Token "$InvoiceId.$exp"
$other = $InvoiceId + 1
$flipped = $tok.Substring(0, $tok.Length - 1) + $(if ($tok[-1] -eq '0') { '1' } else { '0' })

$cases = @(
  @{ Name = "valid signed link returns a PDF";                Url = "${base}?invoice_id=$InvoiceId&exp=$exp&token=$tok";                              Code = "200"; Type = "application/pdf" },
  @{ Name = "no signature at all is rejected";                Url = "${base}?invoice_id=$InvoiceId";                                                  Code = "403" },
  @{ Name = "token for another invoice is rejected";          Url = "${base}?invoice_id=$other&exp=$exp&token=$tok";                                  Code = "403" },
  @{ Name = "expired link is rejected";                       Url = "${base}?invoice_id=$InvoiceId&exp=$old&token=$(Get-Token "$InvoiceId.$old")";    Code = "403" },
  @{ Name = "one wrong character in the token is rejected";   Url = "${base}?invoice_id=$InvoiceId&exp=$exp&token=$flipped";                          Code = "403" },
  @{ Name = "comma-separated ids rejected even if signed";    Url = "${base}?invoice_id=1,2&exp=$exp&token=$(Get-Token "1,2.$exp")";                  Code = "403" },
  @{ Name = "non-numeric id rejected even if signed";         Url = "${base}?invoice_id=abc&exp=$exp&token=$(Get-Token "abc.$exp")";                  Code = "403" }
)

$failed = 0
foreach ($c in $cases) {
  $r = Get-Result $c.Url
  $ok = ($r.Code -eq $c.Code) -and ((-not $c.Type) -or ($r.Type -like "$($c.Type)*"))
  if (-not $ok) { $failed++ }
  "{0}  {1}  (got {2} {3})" -f $(if ($ok) { "PASS" } else { "FAIL" }), $c.Name, $r.Code, $r.Type
}
if ($failed) { "`n$failed case(s) failed"; exit 1 } else { "`nall cases passed" }
