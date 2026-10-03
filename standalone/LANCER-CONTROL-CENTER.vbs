Option Explicit
Dim shell, fso, baseFolder, initPath, managerPath, initCommand, managerCommand, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseFolder = fso.GetParentFolderName(WScript.ScriptFullName)
initPath = baseFolder & "\Initialize-Standalone.ps1"
managerPath = baseFolder & "\tool\RustRPG-Manager.ps1"
initCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & initPath & """"
exitCode = shell.Run(initCommand, 0, True)
If exitCode <> 0 Then
    MsgBox "L'initialisation du Control Center a échoué. Vérifie que PowerShell est disponible.", 16, "Rust Server Control Center"
    WScript.Quit exitCode
End If
managerCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & managerPath & """"
shell.Run managerCommand, 0, False
