# monitor_tiempo_real.ps1
# Observa en TIEMPO REAL, con datos reales de Windows:
#   - Asignacion de CPU: uso por nucleo y procesos con hilos en estado Running
#   - Cola de procesos: Processor Queue Length y procesos con hilos en estado Ready
#   - Cambios de estado: Ready / Running / Waiting, procesos creados y terminados
# Al salir (Ctrl+C) guarda los resultados en la carpeta "monitor_resultados".
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File .\monitor_tiempo_real.ps1
#   (opcional) -IntervaloSeg 1   segundos entre actualizaciones
#   (opcional) -Top 12           procesos mostrados en la tabla
#   (opcional) -DuracionSeg 60   se detiene solo (0 = hasta Ctrl+C)
#   (opcional) -CargaSeg 20      genera carga de CPU durante 20 s para ver crecer la cola
#
# Usa una consola grande (maximizada) y de PowerShell, no ISE.
# Nota: el texto esta sin tildes a proposito, para que se vea bien en cualquier consola.

param(
    [double]$IntervaloSeg = 1,
    [int]$Top = 12,
    [int]$DuracionSeg = 0,
    [int]$CargaSeg = 0
)

$base    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$carpeta = Join-Path $base 'monitor_resultados'
New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
$marca   = Get-Date -Format 'yyyyMMdd_HHmmss'
$nucleos = [Environment]::ProcessorCount

# ---------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------
function Barra([double]$pct, [int]$ancho = 20) {
    $p = [math]::Max(0, [math]::Min(100, $pct))
    $n = [int][math]::Round($ancho * $p / 100)
    return '[' + ('#' * $n) + ('-' * ($ancho - $n)) + ']'
}

# Estado de un proceso a partir del estado de sus hilos (foto del instante)
function Estado-Proceso($proc) {
    $run = 0; $ready = 0; $wait = 0; $total = 0
    try {
        foreach ($t in $proc.Threads) {
            $total++
            switch ($t.ThreadState.ToString()) {
                'Running' { $run++ }
                'Ready'   { $ready++ }
                'Standby' { $ready++ }
                'Wait'    { $wait++ }
            }
        }
    } catch {}
    $estado = '?'
    if     ($run   -gt 0)   { $estado = 'Running' }
    elseif ($ready -gt 0)   { $estado = 'Ready' }
    elseif ($total -gt 0)   { $estado = 'Waiting' }
    return [pscustomobject]@{ Run = $run; Ready = $ready; Wait = $wait; Hilos = $total; Estado = $estado }
}

$script:maxLineas = 0
function Dibujar($lineas) {
    $w = 120
    try { $w = $Host.UI.RawUI.WindowSize.Width } catch {}
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
    foreach ($l in $lineas) {
        $s = [string]$l.T
        if ($s.Length -ge $w) { $s = $s.Substring(0, $w - 1) }
        Write-Host $s.PadRight($w - 1) -ForegroundColor $l.C
    }
    for ($i = $lineas.Count; $i -lt $script:maxLineas; $i++) { Write-Host (' ' * ($w - 1)) }
    if ($lineas.Count -gt $script:maxLineas) { $script:maxLineas = $lineas.Count }
}

# ---------------------------------------------------------------
# Estado del monitor
# ---------------------------------------------------------------
$prev       = @{}                                            # PID -> Cpu (s), Estado, Nombre
$prevTime   = $null
$primera    = $true
$eventos    = New-Object System.Collections.ArrayList        # todos los cambios de estado
$muestras   = New-Object System.Collections.ArrayList        # una fila por actualizacion
$recientes  = New-Object 'System.Collections.Generic.List[object]'
$inicio     = Get-Date
$jobs       = @()

# Carga opcional para ver crecer la cola de listos
if ($CargaSeg -gt 0) {
    for ($i = 0; $i -lt ($nucleos + 2); $i++) {
        $jobs += Start-Job -ArgumentList $CargaSeg -ScriptBlock {
            param($s)
            $fin = (Get-Date).AddSeconds($s)
            $x = 1.0
            while ((Get-Date) -lt $fin) { $x = [math]::Sqrt($x + 1) }
        }
    }
}

try { [Console]::CursorVisible = $false } catch {}
Clear-Host

try {
    while ($true) {
        $t0 = Get-Date
        $dt = 0
        if ($null -ne $prevTime) { $dt = ($t0 - $prevTime).TotalSeconds }

        # --- Lectura del sistema ---
        $procs = @(Get-Process)
        $sys   = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction SilentlyContinue
        $cpus  = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue)
        $tot   = $cpus | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        $cores = @($cpus | Where-Object { $_.Name -ne '_Total' } | Sort-Object { [int](($_.Name -replace '\D', '')) })

        $cpuTotal = 0; $cola = 0; $ctx = 0; $nProc = $procs.Count; $nHilos = 0
        if ($tot) { $cpuTotal = [double]$tot.PercentProcessorTime }
        if ($sys) { $cola = [int]$sys.ProcessorQueueLength; $ctx = [int]$sys.ContextSwitchesPersec; $nProc = [int]$sys.Processes; $nHilos = [int]$sys.Threads }

        # --- Estado y CPU de cada proceso ---
        $filas = @(foreach ($p in $procs) {
            $cpuNow = [double]$p.CPU
            $pct = 0.0
            if ($dt -gt 0 -and $prev.ContainsKey($p.Id)) {
                $pct = [math]::Max(0, ($cpuNow - $prev[$p.Id].Cpu) / $dt / $nucleos * 100)
            }
            $e = Estado-Proceso $p
            [pscustomobject]@{
                Id = $p.Id; Nombre = $p.ProcessName; Cpu = $cpuNow; Pct = $pct
                Run = $e.Run; Ready = $e.Ready; Wait = $e.Wait; Hilos = $e.Hilos; Estado = $e.Estado
                MemMB = [math]::Round($p.WorkingSet64 / 1MB, 1); Proc = $p
            }
        })
        $ordenados = @($filas | Sort-Object @{Expression = 'Pct'; Descending = $true}, @{Expression = 'Run'; Descending = $true})
        $topFilas  = @($ordenados | Select-Object -First $Top)
        $topIds    = @{}
        foreach ($f in $topFilas) { $topIds[$f.Id] = $true }

        # --- Cambios de estado ---
        $hora = $t0.ToString('HH:mm:ss')
        if (-not $primera) {
            foreach ($f in $filas) {
                if (-not $prev.ContainsKey($f.Id)) {
                    $ev = [pscustomobject]@{ Hora = $hora; PID = $f.Id; Proceso = $f.Nombre; Anterior = 'New'; Nuevo = 'Ready'; Tipo = 'creado' }
                    [void]$eventos.Add($ev); $recientes.Add($ev)
                }
                elseif ($prev[$f.Id].Estado -ne $f.Estado -and $topIds.ContainsKey($f.Id)) {
                    $ev = [pscustomobject]@{ Hora = $hora; PID = $f.Id; Proceso = $f.Nombre; Anterior = $prev[$f.Id].Estado; Nuevo = $f.Estado; Tipo = 'cambio' }
                    [void]$eventos.Add($ev); $recientes.Add($ev)
                }
            }
            $actuales = @{}
            foreach ($f in $filas) { $actuales[$f.Id] = $true }
            foreach ($id in @($prev.Keys)) {
                if (-not $actuales.ContainsKey($id)) {
                    $ev = [pscustomobject]@{ Hora = $hora; PID = $id; Proceso = $prev[$id].Nombre; Anterior = $prev[$id].Estado; Nuevo = 'Terminated'; Tipo = 'terminado' }
                    [void]$eventos.Add($ev); $recientes.Add($ev)
                }
            }
            while ($recientes.Count -gt 12) { $recientes.RemoveAt(0) }
        }
        $prev = @{}
        foreach ($f in $filas) { $prev[$f.Id] = @{ Cpu = $f.Cpu; Estado = $f.Estado; Nombre = $f.Nombre } }
        $prevTime = $t0
        $primera = $false

        # --- Metricas globales ---
        $hilosRun   = ($filas | Measure-Object Run   -Sum).Sum
        $hilosReady = ($filas | Measure-Object Ready -Sum).Sum
        [void]$muestras.Add([pscustomobject]@{
            Hora = $hora; CPUTotalPct = $cpuTotal; ColaListos = $cola; HilosRunning = $hilosRun
            HilosReady = $hilosReady; CambiosContextoSeg = $ctx; Procesos = $nProc; Hilos = $nHilos
        })

        # --- Panel ---
        $L = New-Object 'System.Collections.Generic.List[object]'
        $L.Add([pscustomobject]@{ T = "MONITOR EN TIEMPO REAL - Windows | Ctrl+C para salir | cada $IntervaloSeg s | $hora"; C = 'Cyan' })
        $L.Add([pscustomobject]@{ T = 'Estados: Running = usando la CPU | Ready = listo, esperando CPU | Waiting = bloqueado esperando un evento'; C = 'DarkGray' })
        $L.Add([pscustomobject]@{ T = ''; C = 'Gray' })

        $colCpu = 'Green'
        if ($cpuTotal -ge 85) { $colCpu = 'Red' } elseif ($cpuTotal -ge 60) { $colCpu = 'Yellow' }
        $L.Add([pscustomobject]@{ T = ('ASIGNACION DE CPU   Total {0} {1,5:N1} %   ({2} nucleos logicos)' -f (Barra $cpuTotal 30), $cpuTotal, $nucleos); C = $colCpu })

        if ($cores.Count -gt 0 -and $cores.Count -le 24) {
            $linea = ''; $n = 0
            foreach ($c in $cores) {
                $linea += ('CPU{0,-2} {1} {2,3}%   ' -f ($c.Name -replace ',', '.'), (Barra $c.PercentProcessorTime 10), $c.PercentProcessorTime)
                $n++
                if ($n % 3 -eq 0) { $L.Add([pscustomobject]@{ T = $linea; C = 'Gray' }); $linea = '' }
            }
            if ($linea -ne '') { $L.Add([pscustomobject]@{ T = $linea; C = 'Gray' }) }
        }

        $enCpu = @($filas | Where-Object { $_.Run -gt 0 } | Sort-Object Run -Descending | Select-Object -First 8 | ForEach-Object { '{0}({1})' -f $_.Nombre, $_.Run })
        $txtCpu = '(ninguno detectado)'
        if ($enCpu.Count -gt 0) { $txtCpu = $enCpu -join ', ' }
        $L.Add([pscustomobject]@{ T = ('En CPU ahora ({0} hilos Running): {1}' -f $hilosRun, $txtCpu); C = 'Green' })
        $L.Add([pscustomobject]@{ T = ''; C = 'Gray' })

        $colCola = 'Green'
        if ($cola -ge $nucleos) { $colCola = 'Red' } elseif ($cola -gt 0) { $colCola = 'Yellow' }
        $L.Add([pscustomobject]@{ T = ('COLA DE LISTOS   Processor Queue Length: {0} hilos esperando CPU | Hilos Ready ahora: {1} | Cambios de contexto/s: {2}' -f $cola, $hilosReady, $ctx); C = $colCola })
        $listos = @($filas | Where-Object { $_.Ready -gt 0 } | Sort-Object Ready -Descending | Select-Object -First 8 | ForEach-Object { '{0}({1})' -f $_.Nombre, $_.Ready })
        $txtListos = '(ninguno en este instante)'
        if ($listos.Count -gt 0) { $txtListos = $listos -join ', ' }
        $L.Add([pscustomobject]@{ T = ('Ready Queue (procesos con hilos en Ready): {0}' -f $txtListos); C = 'Yellow' })
        $L.Add([pscustomobject]@{ T = ('Procesos: {0} | Hilos: {1}' -f $nProc, $nHilos); C = 'DarkGray' })
        $L.Add([pscustomobject]@{ T = ''; C = 'Gray' })

        $L.Add([pscustomobject]@{ T = ('PROCESOS CON MAS USO DE CPU (top {0})' -f $Top); C = 'Cyan' })
        $L.Add([pscustomobject]@{ T = ('{0,-7}{1,-26}{2,7}{3,7}{4,5}{5,5}{6,6}  {7,-9}{8,10}  {9}' -f 'PID', 'Proceso', 'CPU %', 'Hilos', 'Run', 'Rdy', 'Wait', 'Estado', 'Mem MB', 'Prioridad'); C = 'White' })
        foreach ($f in $topFilas) {
            $prio = '-'
            try { $prio = $f.Proc.PriorityClass.ToString() } catch {}
            $col = 'Gray'
            if ($f.Estado -eq 'Running') { $col = 'Green' } elseif ($f.Estado -eq 'Ready') { $col = 'Yellow' }
            $nombre = $f.Nombre
            if ($nombre.Length -gt 24) { $nombre = $nombre.Substring(0, 24) }
            $L.Add([pscustomobject]@{ T = ('{0,-7}{1,-26}{2,7:N1}{3,7}{4,5}{5,5}{6,6}  {7,-9}{8,10:N1}  {9}' -f $f.Id, $nombre, $f.Pct, $f.Hilos, $f.Run, $f.Ready, $f.Wait, $f.Estado, $f.MemMB, $prio); C = $col })
        }
        $L.Add([pscustomobject]@{ T = ''; C = 'Gray' })

        $L.Add([pscustomobject]@{ T = 'CAMBIOS DE ESTADO (ultimos 12)'; C = 'Cyan' })
        if ($recientes.Count -eq 0) {
            $L.Add([pscustomobject]@{ T = '(esperando cambios... abre o cierra un programa para verlos)'; C = 'DarkGray' })
        }
        else {
            for ($i = $recientes.Count - 1; $i -ge 0; $i--) {
                $ev = $recientes[$i]
                $col = 'Yellow'
                if ($ev.Tipo -eq 'creado') { $col = 'Green' } elseif ($ev.Tipo -eq 'terminado') { $col = 'Red' }
                $L.Add([pscustomobject]@{ T = ('[{0}] PID {1,-6} {2,-24} {3} -> {4}' -f $ev.Hora, $ev.PID, $ev.Proceso, $ev.Anterior, $ev.Nuevo); C = $col })
            }
        }

        Dibujar $L

        if ($DuracionSeg -gt 0 -and ((Get-Date) - $inicio).TotalSeconds -ge $DuracionSeg) { break }

        $trabajo = ((Get-Date) - $t0).TotalMilliseconds
        $espera  = [int][math]::Max(50, $IntervaloSeg * 1000 - $trabajo)
        Start-Sleep -Milliseconds $espera
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    if ($jobs.Count -gt 0) { $jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }

    Write-Host "`n`n=== MONITOR DETENIDO - GUARDANDO RESULTADOS ===" -ForegroundColor Cyan
    if ($muestras.Count -gt 0) {
        $muestras | Export-Csv -Path (Join-Path $carpeta "muestras_$marca.csv") -NoTypeInformation -Encoding UTF8
        $eventos  | Export-Csv -Path (Join-Path $carpeta "cambios_estado_$marca.csv") -NoTypeInformation -Encoding UTF8
        $durSeg   = [math]::Round(((Get-Date) - $inicio).TotalSeconds, 0)
        $prom     = [math]::Round(($muestras | Measure-Object CPUTotalPct -Average).Average, 1)
        $maxCpu   = ($muestras | Measure-Object CPUTotalPct -Maximum).Maximum
        $maxCola  = ($muestras | Measure-Object ColaListos -Maximum).Maximum
        $resumen = @(
            'RESUMEN DEL MONITOR EN TIEMPO REAL'
            "Duracion: $durSeg s | Muestras: $($muestras.Count)"
            "CPU total promedio: $prom % | maximo: $maxCpu %"
            "Cola de listos maxima (Processor Queue Length): $maxCola"
            "Cambios de estado registrados: $($eventos.Count)"
        )
        $resumen | Out-File -FilePath (Join-Path $carpeta "resumen_$marca.txt") -Encoding UTF8
        $resumen | ForEach-Object { Write-Host $_ }
        Write-Host "Archivos guardados en: $carpeta" -ForegroundColor Cyan
    }
}