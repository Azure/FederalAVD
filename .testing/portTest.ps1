$DestIP = '192.168.1.1'
$ErrorActionPreference = 'Silentlycontinue'
$OutputFile = "$env:Temp\portscan.csv"
Set-Content -Path $OutputFile -Value "Port,Status" -Force
For ($i = 1; $i -le 65535; $i++) {
    $PercentComplete = (($i / 65535) * 100)
    $Activity = "Scanning IP Address {0} Port {1}" -f $DestIP, $i
    Write-Progress -Activity $Activity -Status "$PercentComplete% Complete" -PercentComplete $PercentComplete
    $socket = new-object System.Net.Sockets.TcpClient($DestIP, $i)
    If ($socket.Connected) {
        $content = "$i,open"
        $socket.Close() 
    }
    else { 
        $content = "$i,closed"
    }
    Add-Content -Path $OutputFile -Value $content -Force
}