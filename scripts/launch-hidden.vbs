' Launches signal.ps1 with no console window at all.
'
' Every other way of starting PowerShell from a hook flashes a terminal:
' `cmd /c start /b` gives it a fresh console, and even -WindowStyle Hidden
' shows the window for a frame or two before hiding it. WScript.Shell.Run with
' intWindowStyle 0 never creates one in the first place.
'
' Usage: wscript //nologo launch-hidden.vbs <signal.ps1> <signal> <reason>

Option Explicit

Dim args, quoted, command, shell
Set args = WScript.Arguments

If args.Count < 3 Then
    WScript.Quit 1
End If

quoted = Chr(34)
command = "powershell.exe -NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass" & _
          " -File " & quoted & args(0) & quoted & _
          " -Signal " & args(1) & _
          " -Reason " & quoted & args(2) & quoted

Set shell = CreateObject("WScript.Shell")
' 0 = hidden window, False = do not wait for it to finish.
shell.Run command, 0, False
