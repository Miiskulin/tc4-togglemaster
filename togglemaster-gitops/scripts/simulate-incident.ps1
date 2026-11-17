param(
    [string]$Namespace = "togglemaster",
    [int]$Port = 8004,
    [int]$Requests = 45,
    [int]$DelaySeconds = 2
)

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "1. Iniciando port-forward e injetando falha (/debug/break) no evaluation-service" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$pfProcess = Start-Process -FilePath "kubectl" -ArgumentList "port-forward -n $Namespace svc/evaluation-service ${Port}:8004" -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Seconds 3
    $breakResp = Invoke-RestMethod -Method Post -Uri "http://localhost:${Port}/debug/break"
    Write-Host "Falha injetada: $($breakResp | ConvertTo-Json -Compress)" -ForegroundColor Yellow

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "2. Gerando $Requests requisicoes com erro HTTP 500 (>5% error rate)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    for ($i = 1; $i -le $Requests; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:${Port}/evaluate?user_id=user-123&flag_name=checkout-v2" -UseBasicParsing -ErrorAction Stop
            Write-Host "Requisicao #$i -> HTTP $($resp.StatusCode)"
        } catch {
            $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "ERRO" }
            Write-Host "Requisicao #$i -> HTTP $code (Falha Injetada)" -ForegroundColor Red
        }
        Start-Sleep -Seconds $DelaySeconds
    }
} finally {
    if ($pfProcess -and !$pfProcess.HasExited) {
        Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "3. Monitorando os pods sendo reiniciados automaticamente pelo Self-Healing:" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
kubectl get pods -n $Namespace -l "app=evaluation-service" -w
