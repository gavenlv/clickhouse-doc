param(
  [Parameter(Mandatory=$true)][string]$FilePath,
  [string]$Server = 'clickhouse-server-1',
  [switch]$CleanInteg
)
$ErrorActionPreference = 'Continue'

# build marker [<yu qi bao cuo>] via codepoints to keep this file pure ASCII
$marker  = -join [char[]](0x9884, 0x671F, 0x62A5, 0x9519)   # yu qi bao cuo
$expFailPattern = [regex]::Escape([char]0x5B + $marker + [char]0x5D)

if ($CleanInteg) {
  Write-Host '>>> clean File engine leftovers integ_files ...'
  & docker exec $Server rm -rf /var/lib/clickhouse/user_files/integ_files 2>&1 | Out-Null
}

$lines = Get-Content -LiteralPath $FilePath -Encoding UTF8
$script:segments = @()
$script:cur = New-Object System.Text.StringBuilder
$script:pendingComments = @()
$script:startLine = -1

function Flush-Segment {
  if ($script:cur.Length -gt 0) {
    $text = $script:cur.ToString().TrimEnd()
    $cmt = $script:pendingComments -join "`n"
    $script:segments += [PSCustomObject]@{
      text       = $text
      expectFail = ($cmt -match $expFailPattern)
      startLine  = $script:startLine
    }
  }
  $script:cur = New-Object System.Text.StringBuilder
  $script:pendingComments = @()
  $script:startLine = -1
}

$ln = 0
foreach ($line in $lines) {
  $ln++
  $t = $line.Trim()
  if ($t -eq '') { continue }
  if ($t -like '--*') {
    if ($script:cur.Length -eq 0) { $script:pendingComments += $line }
    continue
  }
  if ($script:startLine -lt 0) { $script:startLine = $ln }
  [void]$script:cur.AppendLine($line)
  $m = [regex]::Match($t, ';\s*(--.*)?$')
  if ($m.Success) { Flush-Segment }
}
Flush-Segment

$pass = 0; $fail = 0; $total = 0
foreach ($s in $script:segments) {
  $q = $s.text.Trim()
  if ($q -eq '') { continue }
  $total++
  $tag = if ($s.expectFail) { '[EXPECT-FAIL]' } else { '' }
  Write-Host "----- L$($s.startLine) $tag -----"
  $out = & docker exec $Server clickhouse-client --multiquery --format Null --query $q 2>&1
  $code = $LASTEXITCODE
  if ($s.expectFail) {
    if ($code -ne 0) {
      $pass++
      $errLines = ($out | Select-Object -First 4) -join ' | '
      Write-Host "  OK(expected-fail exit=$code) first error: $errLines"
    } else {
      $fail++
      Write-Host "  !! expected fail but SUCCEEDED exit=0"
    }
  } else {
    if ($code -eq 0) {
      $pass++
      Write-Host "  OK exit=0"
    } else {
      $fail++
      $errLines = ($out | Select-Object -First 4) -join ' | '
      Write-Host "  !! FAIL exit=$code : $errLines"
    }
  }
}
Write-Host "=== $FilePath : TOTAL=$total PASS=$pass FAIL=$fail ==="
exit $fail
