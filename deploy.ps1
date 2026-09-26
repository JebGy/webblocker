param(
    [string]$WebhookUrl = "http://31.97.31.103:3000/api/compose/deploy/d58bc1510ada6c2f345dacc4d50d2cb97fbce71ba88dcd7c"
)

Write-Host "Disparando despliegue en Easypanel..." -ForegroundColor Cyan
try {
    $resp = Invoke-RestMethod -Uri $WebhookUrl -Method Post -TimeoutSec 15
    Write-Host "Despliegue iniciado exitosamente: $($resp | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    # Fallback to GET if POST is not accepted
    try {
        $resp = Invoke-RestMethod -Uri $WebhookUrl -Method Get -TimeoutSec 15
        Write-Host "Despliegue iniciado con GET: $($resp | ConvertTo-Json -Compress)" -ForegroundColor Green
    } catch {
        Write-Error "Fallo al disparar despliegue: $_"
    }
}
