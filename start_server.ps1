# Get script root directory
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

$BackendLog = "$PSScriptRoot\.backend.log"
$TunnelLog = "$PSScriptRoot\.tunnel.log"
$UrlFile = "$PSScriptRoot\server_url.txt"

# Cleanup function to kill background processes
function Cleanup-Processes {
    Write-Host "Limpando processos antigos..." -ForegroundColor Yellow
    if ($global:BackendProc) {
        Stop-Process -Id $global:BackendProc.Id -Force -ErrorAction SilentlyContinue
    }
    if ($global:TunnelProc) {
        Stop-Process -Id $global:TunnelProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $BackendLog, $TunnelLog -ErrorAction SilentlyContinue
}

# Trap to catch Ctrl+C and exit gracefully
trap {
    Write-Host "`nScript interrompido pelo usuário." -ForegroundColor Red
    Cleanup-Processes
    exit
}

try {
    # 0. Clean up any previous run
    Cleanup-Processes

    # 1. Start Backend (Uvicorn)
    Write-Host "Iniciando backend (Uvicorn)..." -ForegroundColor Cyan
    $global:BackendProc = Start-Process -FilePath "uvicorn" -ArgumentList "main:app --host 0.0.0.0 --port 8000" `
        -WorkingDirectory "$PSScriptRoot\server" `
        -RedirectStandardOutput $BackendLog `
        -RedirectStandardError $BackendLog `
        -NoNewWindow -PassThru

    # Wait a few seconds to ensure backend is starting
    Start-Sleep -Seconds 3

    # 2. Start Cloudflare Tunnel
    Write-Host "Iniciando Cloudflare Tunnel..." -ForegroundColor Cyan
    $CloudflaredPath = "$PSScriptRoot\server\cloudflared.exe"
    if (-not (Test-Path $CloudflaredPath)) {
        Write-Host "cloudflared.exe não encontrado em $CloudflaredPath! Baixando..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $CloudflaredPath
    }

    $global:TunnelProc = Start-Process -FilePath $CloudflaredPath -ArgumentList "tunnel --url http://127.0.0.1:8000" `
        -RedirectStandardOutput $TunnelLog `
        -RedirectStandardError $TunnelLog `
        -NoNewWindow -PassThru

    # 3. Wait for Cloudflare URL
    Write-Host "Aguardando URL pública da Cloudflare..." -ForegroundColor Cyan
    $TunnelUrl = ""
    for ($i = 1; $i -le 40; $i++) {
        if (Test-Path $TunnelLog) {
            $LogContent = Get-Content -Path $TunnelLog -Raw
            if ($LogContent -match 'https://[-a-z0-9]+\.trycloudflare\.com') {
                $TunnelUrl = $Matches[0]
                break
            }
        }
        Start-Sleep -Seconds 1
    }

    if (-not $TunnelUrl) {
        Write-Error "Não foi possível obter a URL do Cloudflare Tunnel. Verifique o log em $TunnelLog."
        Cleanup-Processes
        exit 1
    }

    Write-Host "URL Pública gerada: $TunnelUrl" -ForegroundColor Green

    # 4. Save URL to file
    $TunnelUrl | Out-File -FilePath $UrlFile -Encoding utf8 -NoNewline
    Write-Host "URL salva em $UrlFile" -ForegroundColor Gray

    # 5. Commit and Push to GitHub
    Write-Host "Enviando URL para o repositório GitHub..." -ForegroundColor Cyan
    if (Test-Path "$PSScriptRoot\.git") {
        git add "$UrlFile"
        # Check if there are changes
        $GitStatus = git status --porcelain
        if ($GitStatus) {
            git commit -m "Atualizando server_url.txt para $TunnelUrl"
            git push origin main
            Write-Host "Commit enviado com sucesso para o GitHub!" -ForegroundColor Green
        } else {
            Write-Host "Nenhuma alteração detectada no Git (URL idêntica)." -ForegroundColor Gray
        }
    } else {
        Write-Host "Aviso: Git não inicializado na raiz do projeto. Crie um repositório git e configure o remote para habilitar push automático." -ForegroundColor Yellow
    }

    Write-Host "`nServidor rodando e URL pública ativa!" -ForegroundColor Green
    Write-Host "Segure Ctrl + C para fechar o servidor e o túnel.`n" -ForegroundColor Yellow
    Write-Host "-------------------- LOGS DO BACKEND --------------------" -ForegroundColor Gray

    # Tailing the backend log
    Get-Content -Path $BackendLog -Wait
}
finally {
    Cleanup-Processes
}
