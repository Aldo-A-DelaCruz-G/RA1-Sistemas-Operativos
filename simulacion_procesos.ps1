# ==============================================================
# RA1 - Sistemas Operativos
# Simulacion de gestion de procesos en Windows con PowerShell
# Parte 1: Planificacion Round Robin (tabla PCB, cola de listos, Gantt)
# Parte 2: Round Robin REAL sobre procesos de Windows (ver Administrador de tareas)
# Parte 3: Comunicacion (archivo compartido) y sincronizacion (Mutex)
# Compatible con Windows PowerShell 5.1 y PowerShell 7
# Uso:  .\simulacion_procesos.ps1            (con pausas para capturas)
#       .\simulacion_procesos.ps1 -SinPausas (sin pausas)
# ==============================================================
param(
    [int]$Quantum = 2,
    [int]$QuantumReal = 3,
    [switch]$SinPausas
)

$EsWindows = ($env:OS -eq 'Windows_NT')

function Pausa([string]$msg) {
    if (-not $SinPausas) { Read-Host "`n>> $msg (Enter para continuar)" | Out-Null }
}
function Titulo([string]$t) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $t -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

# --------------------------------------------------------------
# PARTE 1 - Simulacion Round Robin
# Estados: Nuevo -> Listo -> Ejecutando -> (Listo | Terminado)
# --------------------------------------------------------------
Titulo "PARTE 1: Simulacion Round Robin (Quantum = $Quantum)"

$procesos = @(
    [pscustomobject]@{ Id='P1'; Llegada=0; Burst=5; Restante=5; Estado='Nuevo'; Fin=0 },
    [pscustomobject]@{ Id='P2'; Llegada=1; Burst=3; Restante=3; Estado='Nuevo'; Fin=0 },
    [pscustomobject]@{ Id='P3'; Llegada=2; Burst=4; Restante=4; Estado='Nuevo'; Fin=0 },
    [pscustomobject]@{ Id='P4'; Llegada=3; Burst=2; Restante=2; Estado='Nuevo'; Fin=0 }
)

Write-Host "`nTabla de procesos (PCB simplificado):"
$procesos | Format-Table Id, Llegada, Burst, Restante, Estado -AutoSize | Out-String -Width 120 | Write-Host
Pausa "Captura de la tabla de procesos"

$cola       = New-Object System.Collections.Queue
$actual     = $null
$usoQuantum = 0
$expropiado = $null
$terminados = 0
$t          = 0
$gantt      = @()

while ($terminados -lt $procesos.Count) {
    $eventos = @()

    # 1) Llegadas en el instante t (entran antes que el proceso expropiado)
    foreach ($p in $procesos) {
        if ($p.Llegada -eq $t) {
            $p.Estado = 'Listo'
            $cola.Enqueue($p)
            $eventos += "$($p.Id): Nuevo -> Listo"
        }
    }
    # 2) El proceso expropiado en el tick anterior vuelve al final de la cola
    if ($expropiado) {
        $cola.Enqueue($expropiado)
        $expropiado = $null
    }
    # 3) Despachador: si la CPU esta libre, toma el primero de la cola
    if (-not $actual -and $cola.Count -gt 0) {
        $actual = $cola.Dequeue()
        $actual.Estado = 'Ejecutando'
        $usoQuantum = 0
        $eventos += "$($actual.Id): Listo -> Ejecutando"
    }

    # Cola de listos durante este tick (despues del despacho)
    $listos = ($cola.ToArray() | ForEach-Object { $_.Id }) -join ','
    if (-not $listos) { $listos = '(vacia)' }

    # 4) Ejecutar un tick
    if ($actual) {
        $quien = $actual.Id
        $actual.Restante--
        $usoQuantum++
        $gantt += $quien
        if ($actual.Restante -eq 0) {
            $actual.Estado = 'Terminado'
            $actual.Fin = $t + 1
            $terminados++
            $eventos += "$($actual.Id): Ejecutando -> Terminado"
            $rest = 0
            $actual = $null
        }
        else {
            $rest = $actual.Restante
            if ($usoQuantum -ge $Quantum) {
                $expropiado = $actual
                $eventos += "$($actual.Id): Ejecutando -> Listo (fin de quantum)"
                $actual = $null
            }
        }
        $cpu = "$quien (restante $rest)"
    }
    else {
        $gantt += '--'
        $cpu = 'CPU libre'
    }

    $ev = if ($eventos.Count -gt 0) { $eventos -join ' | ' } else { '-' }
    Write-Host ("t={0,2}->{1,2} | CPU: {2,-16} | Cola: {3,-12} | {4}" -f $t, ($t+1), $cpu, $listos, $ev)
    $t++
}

Write-Host "`nDiagrama de Gantt (cada casilla = 1 unidad de tiempo):"
Write-Host ("|" + (($gantt | ForEach-Object { " $_ " }) -join "|") + "|")
$marcas = (0..$gantt.Count | ForEach-Object { "{0,-5}" -f $_ }) -join ""
Write-Host $marcas

Write-Host "`nMetricas:"
$resultado = foreach ($p in $procesos) {
    $retorno = $p.Fin - $p.Llegada
    [pscustomobject]@{
        Proceso = $p.Id; Llegada = $p.Llegada; Burst = $p.Burst; Fin = $p.Fin
        Retorno = $retorno; Espera = $retorno - $p.Burst
    }
}
$resultado | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
$promRet = ($resultado | Measure-Object Retorno -Average).Average
$promEsp = ($resultado | Measure-Object Espera  -Average).Average
$util    = [math]::Round((($gantt | Where-Object { $_ -ne '--' }).Count / $gantt.Count) * 100, 1)
Write-Host ("Tiempo de retorno promedio : {0}" -f $promRet)
Write-Host ("Tiempo de espera promedio  : {0}" -f $promEsp)
Write-Host ("Utilizacion de CPU         : {0} %" -f $util)
Pausa "Captura del Gantt y las metricas"

# --------------------------------------------------------------
# PARTE 2 - Round Robin REAL con procesos de Windows
# Se crean 3 procesos que consumen CPU, se suspenden todos y se
# reanuda uno a la vez durante $QuantumReal segundos.
# Observar en Administrador de tareas > Detalles (columnas PID,
# Estado, CPU). El estado "Suspendido" aparece al suspenderlos.
# --------------------------------------------------------------
Titulo "PARTE 2: Round Robin real con procesos de Windows"

if (-not $EsWindows) {
    Write-Host "Esta parte solo se ejecuta en Windows (usa NtSuspendProcess). Se omite." -ForegroundColor Yellow
}
else {
    Add-Type -Namespace Win32 -Name Proc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtSuspendProcess(System.IntPtr handle);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtResumeProcess(System.IntPtr handle);
'@

    $cmdCpu = '$f=(Get-Date).AddSeconds(120); while((Get-Date) -lt $f){ $x = 1+1 }'
    $reales = @()
    foreach ($n in 1..3) {
        $pr = Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Minimized','-Command',$cmdCpu -PassThru
        $reales += [pscustomobject]@{ Nombre = "R$n"; Proc = $pr }
    }
    Start-Sleep -Seconds 2
    Write-Host "`nProcesos creados (PID reales):"
    $reales | ForEach-Object { "{0} -> PID {1}" -f $_.Nombre, $_.Proc.Id } | Write-Host

    # Suspender todos (estado: Listo/Bloqueado, sin usar CPU)
    foreach ($r in $reales) { [Win32.Proc]::NtSuspendProcess($r.Proc.Handle) | Out-Null }
    Write-Host "Todos suspendidos. Abrir el Administrador de tareas > Detalles."
    Pausa "Captura 1: los 3 procesos aparecen como Suspendido"

    # Dos vueltas de Round Robin
    foreach ($vuelta in 1..2) {
        foreach ($r in $reales) {
            Write-Host ("[Vuelta {0}] {1} (PID {2}) -> EJECUTANDO durante {3} s" -f $vuelta, $r.Nombre, $r.Proc.Id, $QuantumReal) -ForegroundColor Green
            [Win32.Proc]::NtResumeProcess($r.Proc.Handle) | Out-Null
            Start-Sleep -Seconds $QuantumReal
            $cpuSeg = [math]::Round((Get-Process -Id $r.Proc.Id).CPU, 2)
            [Win32.Proc]::NtSuspendProcess($r.Proc.Handle) | Out-Null
            Write-Host ("            {0} -> LISTO (suspendido). CPU acumulada: {1} s" -f $r.Nombre, $cpuSeg)
            if ($vuelta -eq 1 -and $r.Nombre -eq 'R2') {
                Pausa "Captura 2: R1 y R3 suspendidos, R2 acaba de ejecutarse"
            }
        }
    }

    Write-Host "`nResumen de procesos reales:"
    Get-Process -Id ($reales | ForEach-Object { $_.Proc.Id }) |
        Select-Object Id, ProcessName, @{n='CPU_s';e={[math]::Round($_.CPU,2)}}, PriorityClass, @{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB,1)}} |
        Format-Table -AutoSize | Out-String -Width 120 | Write-Host
    Pausa "Captura 3: tabla de Get-Process"

    # Terminar los procesos (estado Terminado)
    foreach ($r in $reales) {
        [Win32.Proc]::NtResumeProcess($r.Proc.Handle) | Out-Null
        Stop-Process -Id $r.Proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $vivos = Get-Process -Id ($reales | ForEach-Object { $_.Proc.Id }) -ErrorAction SilentlyContinue
    if ($vivos) { Write-Host "Aun hay procesos vivos." -ForegroundColor Red }
    else        { Write-Host "Los 3 procesos fueron terminados (Stop-Process)." -ForegroundColor Green }
}

# --------------------------------------------------------------
# PARTE 3 - Comunicacion (archivo compartido) y sincronizacion (Mutex)
# Dos procesos independientes (Start-Job): Productor y Consumidor.
# El Mutex con nombre garantiza exclusion mutua sobre el archivo.
# --------------------------------------------------------------
Titulo "PARTE 3: Comunicacion y sincronizacion con Mutex"

$archivo = Join-Path ([System.IO.Path]::GetTempPath()) 'ra1_buzon.txt'
if (Test-Path $archivo) { Remove-Item $archivo -Force }
New-Item $archivo -ItemType File -Force | Out-Null
$nombreMutex = 'Local\RA1_Mutex_Buzon'
$total = 5

$productor = {
    param($archivo, $nombreMutex, $total)
    $m = New-Object System.Threading.Mutex($false, $nombreMutex)
    foreach ($i in 1..$total) {
        [void]$m.WaitOne()                          # entra a la seccion critica
        try {
            "[$(Get-Date -Format 'HH:mm:ss.fff')] Productor: ENTRA a la seccion critica (Mutex adquirido)"
            Add-Content -Path $archivo -Value "MSG$i"
            "[$(Get-Date -Format 'HH:mm:ss.fff')] Productor: escribio MSG$i"
            Start-Sleep -Milliseconds 300
        }
        finally {
            $m.ReleaseMutex()                        # sale de la seccion critica
        }
        "[$(Get-Date -Format 'HH:mm:ss.fff')] Productor: SALE (Mutex liberado)"
        Start-Sleep -Milliseconds 200
    }
}

$consumidor = {
    param($archivo, $nombreMutex, $total)
    $m = New-Object System.Threading.Mutex($false, $nombreMutex)
    $leidos = 0
    $limite = (Get-Date).AddSeconds(30)
    while ($leidos -lt $total -and (Get-Date) -lt $limite) {
        [void]$m.WaitOne()
        try {
            $lineas = @(Get-Content -Path $archivo)
            while ($leidos -lt $lineas.Count) {
                $hora = Get-Date -Format 'HH:mm:ss.fff'
                "[$hora] Consumidor: leyo $($lineas[$leidos])"
                $leidos++
            }
        }
        finally { $m.ReleaseMutex() }
        Start-Sleep -Milliseconds 250
    }
}

$j1 = Start-Job -ScriptBlock $productor  -ArgumentList $archivo, $nombreMutex, $total
$j2 = Start-Job -ScriptBlock $consumidor -ArgumentList $archivo, $nombreMutex, $total
Write-Host "Jobs iniciados (procesos independientes): Productor Id=$($j1.Id), Consumidor Id=$($j2.Id)"
Wait-Job $j1, $j2 -Timeout 40 | Out-Null
$salida = @(Receive-Job $j1) + @(Receive-Job $j2)
$salida | Sort-Object | ForEach-Object { Write-Host $_ }
Remove-Job $j1, $j2 -Force

Write-Host "`nContenido final del buzon compartido ($archivo):"
Get-Content $archivo | ForEach-Object { Write-Host "  $_" }
Pausa "Captura de la comunicacion y sincronizacion"

Titulo "FIN DE LA SIMULACION"
