# =============================================================================
#  🦀 MOTOBASE — Node.js no Windows, em uma linha
#
#  No PowerShell (como Administrador):
#    irm https://get.motobot.com.br/node | iex
#
#  Instala o Node.js LTS (que traz o npm) e te deixa pronto pro:
#    npm install -g @anthropic-ai/claude-code
# =============================================================================
$ErrorActionPreference = 'Stop'
Write-Host ""
Write-Host "  MOTOBASE - preparando seu computador (Node.js LTS)" -ForegroundColor Yellow
Write-Host ""

# destrava a politica de execucao (o Windows vem travado e bloquearia o npm)
try {
  if ((Get-ExecutionPolicy -Scope CurrentUser) -in @('Restricted','Undefined','AllSigned')) {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Write-Host "  Politica de scripts liberada pro seu usuario (RemoteSigned)." -ForegroundColor Gray
  }
} catch {}

# ja tem?
if (Get-Command node -ErrorAction SilentlyContinue) {
  Write-Host "  Node ja instalado: $(node -v) - nada a fazer." -ForegroundColor Green
  Write-Host ""
  Write-Host "  Proximo passo:  npm install -g @anthropic-ai/claude-code" -ForegroundColor Cyan
  return
}

$ok = $false
# caminho 1: winget (vem no Windows 10/11 atualizado)
if (Get-Command winget -ErrorAction SilentlyContinue) {
  Write-Host "  Instalando via winget..." -ForegroundColor Gray
  winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -eq 0) { $ok = $true }
}

# caminho 2: baixar o instalador oficial direto do nodejs.org
if (-not $ok) {
  Write-Host "  winget indisponivel - baixando instalador oficial do nodejs.org..." -ForegroundColor Gray
  $lts = (Invoke-RestMethod 'https://nodejs.org/dist/index.json') | Where-Object { $_.lts } | Select-Object -First 1
  $v = $lts.version
  $msi = "$env:TEMP\node-$v-x64.msi"
  Invoke-WebRequest "https://nodejs.org/dist/$v/node-$v-x64.msi" -OutFile $msi
  Write-Host "  Instalando $v (silencioso)..." -ForegroundColor Gray
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
  $ok = $true
}

Write-Host ""
Write-Host "  Node.js instalado." -ForegroundColor Green
Write-Host ""
Write-Host "  IMPORTANTE: FECHE esta janela e abra o PowerShell DE NOVO" -ForegroundColor Yellow
Write-Host "  (so a janela nova enxerga o npm). Depois cole:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    npm install -g @anthropic-ai/claude-code" -ForegroundColor Cyan
Write-Host ""
