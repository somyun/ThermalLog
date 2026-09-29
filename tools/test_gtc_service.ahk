#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\..\Lib\Gdip_All.ahk
#Include %A_ScriptDir%\..\src\GtcService.ahk

if (A_PtrSize != 4)
    throw Error("이 검증 스크립트는 32비트 AutoHotkey로 실행해야 합니다.")

inputPath := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\..\RB02991Y.JPG"
outputDir := A_Args.Length >= 2 ? A_Args[2] : A_Temp "\thermal-gtc-service-test"
DirCreate(outputDir)
statusPath := outputDir "\status.log"
FileAppend("start`n", statusPath, "UTF-8")

state := 0
try {
    FileAppend("load`n", statusPath, "UTF-8")
    state := GtcService.Load(inputPath)
    FileAppend("loaded`n", statusPath, "UTF-8")
    markers := []
    marker := GtcService.AddMarker(state, markers, 240, 180)
    FileAppend("marked`n", statusPath, "UTF-8")
    GtcService.RenderPreview(state, markers, "thermal", outputDir "\preview.png")
    FileAppend("previewed`n", statusPath, "UTF-8")
    GtcService.SaveOutputs(
        state,
        markers,
        outputDir "\processed-X.JPG",
        outputDir "\processed-Y.JPG"
    )
    FileAppend("saved`n", statusPath, "UTF-8")
    FileAppend(
        "temperature=" marker["displayTemperature"] "`n"
        "preview=" outputDir "\preview.png`n"
        "thermal=" outputDir "\processed-X.JPG`n"
        "visible=" outputDir "\processed-Y.JPG`n",
        "*"
    )
} finally {
    if IsObject(state)
        GtcService.Close(state)
    GtcService.Shutdown()
}
