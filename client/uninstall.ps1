$TaskName = "WebBlockAgent"
Write-Host "Deteniendo y desinstalando $TaskName..." -ForegroundColor Yellow
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "$TaskName desinstalado." -ForegroundColor Green
