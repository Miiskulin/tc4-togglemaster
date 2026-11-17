param(
    [string]$Namespace = "togglemaster",
    [int]$Requests = 15,
    [switch]$SkipSeed
)

$ErrorActionPreference = "Stop"

function Start-PortForward($SvcName, $Port) {
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    $proc = Start-Process -FilePath "kubectl" -ArgumentList "port-forward -n $Namespace svc/$SvcName ${Port}:${Port}" -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:${Port}/health" -TimeoutSec 2
            return $proc
        } catch {}
    }
    throw "Nao foi possivel conectar em http://localhost:${Port}/health ($SvcName)"
}

$procs = @()
try {
    if (-not $SkipSeed) {
        Write-Host "1. Abrindo port-forward para auth, flag e targeting..." -ForegroundColor Cyan
        $procs += Start-PortForward "auth-service" 8001
        $procs += Start-PortForward "flag-service" 8002
        $procs += Start-PortForward "targeting-service" 8003

        Write-Host "2. Gerando SERVICE_API_KEY no auth-service..." -ForegroundColor Cyan
        $KeyResp = Invoke-RestMethod -Method Post -Uri "http://localhost:8001/admin/keys" `
            -Headers @{ Authorization = "Bearer tm-master-key-2026" } `
            -ContentType "application/json" `
            -Body '{"name":"evaluation-service"}'
        $ApiKey = $KeyResp.key

        kubectl create secret generic evaluation-service-secret -n $Namespace `
            --from-literal=SERVICE_API_KEY="$ApiKey" `
            --dry-run=client -o yaml | kubectl apply -f - | Out-Null

        Write-Host "3. Reiniciando evaluation-service para carregar a nova SERVICE_API_KEY..." -ForegroundColor Cyan
        kubectl rollout restart deployment/evaluation-service -n $Namespace | Out-Null
        kubectl rollout status deployment/evaluation-service -n $Namespace --timeout=120s | Out-Null

        Write-Host "4. Garantindo flag 'checkout-v2' e regra de segmentacao (100%)..." -ForegroundColor Cyan
        try {
            $null = Invoke-RestMethod -Method Post -Uri "http://localhost:8002/flags" `
                -Headers @{ Authorization = "Bearer $ApiKey" } `
                -ContentType "application/json" `
                -Body '{"name":"checkout-v2","description":"Novo checkout Fase 4","is_enabled":true}'
            Write-Host "   Flag 'checkout-v2' criada." -ForegroundColor Green
        } catch {
            Write-Host "   Flag 'checkout-v2' ja existe." -ForegroundColor Yellow
        }

        try {
            $null = Invoke-RestMethod -Method Post -Uri "http://localhost:8003/rules" `
                -Headers @{ Authorization = "Bearer $ApiKey" } `
                -ContentType "application/json" `
                -Body '{"flag_name":"checkout-v2","is_enabled":true,"rules":{"type":"PERCENTAGE","value":100}}'
            Write-Host "   Regra para 'checkout-v2' criada." -ForegroundColor Green
        } catch {
            Write-Host "   Regra para 'checkout-v2' ja existe." -ForegroundColor Yellow
        }
    }

    Write-Host "5. Abrindo port-forward para evaluation-service (8004) e gerando $Requests requisicoes..." -ForegroundColor Cyan
    $procs += Start-PortForward "evaluation-service" 8004

    for ($i = 1; $i -le $Requests; $i++) {
        $resp = Invoke-RestMethod -Uri "http://localhost:8004/evaluate?user_id=user-$i&flag_name=checkout-v2"
        Write-Host "   Requisicao #$i -> flag=$($resp.flag_name) user=$($resp.user_id) result=$($resp.result)" -ForegroundColor Green
        Start-Sleep -Milliseconds 500
    }

    Write-Host "`nTrafego concluido com sucesso! Os spans foram enviados para o OTel Collector." -ForegroundColor Green
} finally {
    foreach ($p in $procs) {
        if ($p -and !$p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
