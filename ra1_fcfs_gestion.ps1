# ra1_fcfs_gestion.ps1
# Parte 1: simulacion FCFS con 9 procesos
# Parte 2: gestion de un proceso real (crear, consultar, cambiar prioridad, finalizar)
# Nota: el texto esta sin tildes a proposito, para que se vea bien en cualquier consola.

Write-Host "=== PARTE 1: SIMULACION FCFS ===" -ForegroundColor Cyan

$procesos = @(
    [pscustomobject]@{ Orden=1; Id='P1'; Nombre='notepad';      Burst=3; Prioridad=1; Llegada=0 },
    [pscustomobject]@{ Orden=2; Id='P2'; Nombre='cmd';          Burst=2; Prioridad=8; Llegada=0 },
    [pscustomobject]@{ Orden=3; Id='P3'; Nombre='mspaint';      Burst=5; Prioridad=4; Llegada=0 },
    [pscustomobject]@{ Orden=4; Id='P4'; Nombre='charmap';      Burst=4; Prioridad=3; Llegada=0 },
    [pscustomobject]@{ Orden=5; Id='P5'; Nombre='powershell';   Burst=3; Prioridad=5; Llegada=0 },
    [pscustomobject]@{ Orden=6; Id='P6'; Nombre='msedge';       Burst=6; Prioridad=2; Llegada=0 },
    [pscustomobject]@{ Orden=7; Id='P7'; Nombre='snippingtool'; Burst=2; Prioridad=6; Llegada=0 },
    [pscustomobject]@{ Orden=8; Id='P8'; Nombre='mstsc';        Burst=4; Prioridad=7; Llegada=0 },
    [pscustomobject]@{ Orden=9; Id='P9'; Nombre='regedit';      Burst=3; Prioridad=9; Llegada=0 }
)

Write-Host "`nProcesos creados (todos llegan en el Tick 0):"
$procesos | Format-Table Id, Nombre, Burst, Prioridad, Llegada -AutoSize

# FCFS: se atiende por orden de llegada (y por orden de creacion si empatan)
$cola = $procesos | Sort-Object Llegada, Orden

$tiempo = 0
$resultados = @()
foreach ($p in $cola) {
    if ($tiempo -lt $p.Llegada) { $tiempo = $p.Llegada }
    $inicio = $tiempo
    $fin    = $inicio + $p.Burst
    $resultados += [pscustomobject]@{
        Proceso = "$($p.Id) - $($p.Nombre)"
        Burst   = $p.Burst
        Inicio  = $inicio
        Fin     = $fin
        Espera  = $inicio - $p.Llegada
        Retorno = $fin - $p.Llegada
    }
    $tiempo = $fin
}

Write-Host "Resultados FCFS:"
$resultados | Format-Table -AutoSize

$promEspera  = ($resultados | Measure-Object Espera  -Average).Average
$promRetorno = ($resultados | Measure-Object Retorno -Average).Average
"Promedio de espera:  {0:N2}" -f $promEspera
"Promedio de retorno: {0:N2}" -f $promRetorno

# Ejecucion tick a tick del primer proceso (Ready -> Running)
Write-Host "`nEjecucion tick a tick de $($cola[0].Id):" -ForegroundColor Yellow
$p1 = $cola[0]
for ($t = 1; $t -le $p1.Burst; $t++) {
    $restante = $p1.Burst - ($t - 1)
    "Tick $t | Running: $($p1.Id) - $($p1.Nombre) | Remaining: $restante | Ready: $($cola.Count - 1)"
    Start-Sleep -Seconds 1
}

Write-Host "`n=== PARTE 2: GESTION DE UN PROCESO REAL ===" -ForegroundColor Cyan
Write-Host "Abre el Administrador de tareas (Ctrl + Shift + Esc) > pestana Detalles para ver el proceso." -ForegroundColor Yellow

# Se usa charmap porque el Bloc de notas en Windows 11 se relanza con otro PID.
$p = Start-Process charmap -PassThru
Start-Sleep -Seconds 2
"PID asignado: $($p.Id)"

Get-Process -Id $p.Id |
    Select-Object Id, ProcessName, CPU, PriorityClass, Responding,
        @{ n='Memoria(MB)'; e={ [math]::Round($_.WS / 1MB, 1) } } |
    Format-List

$p.PriorityClass = 'AboveNormal'
"Prioridad cambiada a: $($p.PriorityClass) (verificala en Detalles)"
Start-Sleep -Seconds 8

Stop-Process -Id $p.Id -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
    "El proceso sigue activo."
} else {
    "El proceso $($p.Id) termino (estado: Terminado)."
}
$promEspera  = ($resultados | Measure-Object Espera  -Average).Average
$promRetorno = ($resultados | Measure-Object Retorno -Average).Average
"Promedio de espera:  {0:N2}" -f $promEspera
"Promedio de retorno: {0:N2}" -f $promRetorno

# Ejecucion tick a tick del primer proceso (Ready -> Running)
Write-Host "`nEjecucion tick a tick de $($cola[0].Id):" -ForegroundColor Yellow
$p1 = $cola[0]
for ($t = 1; $t -le $p1.Burst; $t++) {
    $restante = $p1.Burst - ($t - 1)
    "Tick $t | Running: $($p1.Id) - $($p1.Nombre) | Remaining: $restante | Ready: $($cola.Count - 1)"
    Start-Sleep -Seconds 1
}

Write-Host "`n=== PARTE 2: GESTION DE UN PROCESO REAL ===" -ForegroundColor Cyan
Write-Host "Abre el Administrador de tareas (Ctrl + Shift + Esc) > pestana Detalles para ver el proceso." -ForegroundColor Yellow

# En Windows 11 el Bloc de notas puede relanzarse con otro PID.
# Si el PID no coincide con el del Administrador de tareas, cambia 'notepad' por 'charmap' o 'cmd'.
$p = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
"PID asignado: $($p.Id)"

Get-Process -Id $p.Id |
    Select-Object Id, ProcessName, CPU, PriorityClass, Responding,
        @{ n='Memoria(MB)'; e={ [math]::Round($_.WS / 1MB, 1) } } |
    Format-List

$p.PriorityClass = 'AboveNormal'
"Prioridad cambiada a: $($p.PriorityClass) (verificala en Detalles)"
Start-Sleep -Seconds 8

Stop-Process -Id $p.Id
Start-Sleep -Seconds 1
if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
    "El proceso sigue activo."
} else {
    "El proceso $($p.Id) termino (estado: Terminado)."
}
