#Requires AutoHotkey v2.0
#SingleInstance Force

#Include %A_ScriptDir%\..\Lib\Promise.ahk
#Include %A_ScriptDir%\..\Lib\WebView2.ahk
#Include %A_ScriptDir%\..\Lib\JSON.ahk
#Include %A_ScriptDir%\..\Lib\Gdip_All.ahk
#Include %A_ScriptDir%\..\src\DeviceService.ahk
#Include %A_ScriptDir%\..\src\DocumentService.ahk
#Include %A_ScriptDir%\..\src\ImageService.ahk
#Include %A_ScriptDir%\..\src\SessionService.ahk
#Include %A_ScriptDir%\..\src\GtcService.ahk

global WM_DEVICECHANGE := 0x0219
global DBT_DEVICEARRIVAL := 0x8000
global DBT_DEVICEREMOVECOMPLETE := 0x8004

global AppGui := 0
global WebViewController := 0
global WebViewCore := 0
global UiReady := false
global CameraWasConnected := false
global CurrentCamera := Map("connected", false)
global CurrentTemplate := 0
global CurrentPhotos := 0
global CurrentSession := 0
global CurrentGtcState := 0
global CurrentMarkerMode := "thermal"
global MarkerPreviewVersion := 0
global ResumePromptShown := false
global ResultDocumentPath := ""
global LastScanReason := "프로그램 시작"

Ensure32BitRuntime()
StartApplication()

Ensure32BitRuntime() {
    if (A_PtrSize = 4)
        return

    if !A_IsCompiled {
        ahk32 := A_ProgramFiles "\AutoHotkey\v2\AutoHotkey32.exe"
        if FileExist(ahk32) {
            Run('"' ahk32 '" "' A_ScriptFullPath '"')
            ExitApp()
        }
    }

    MsgBox(
        "통합 온도마커 기능은 32비트 AutoHotkey가 필요합니다.`n"
        "이 프로그램을 32비트로 실행하거나 컴파일해 주세요.",
        "열화상 일지",
        "Iconx"
    )
    ExitApp()
}

StartApplication() {
    global AppGui, WebViewController, WebViewCore

    try {
        WriteAppLog("프로그램을 시작합니다.")

        AppGui := Gui("+Resize +MinSize640x580", "열화상 일지")
        AppGui.BackColor := "F4F7F6"
        AppGui.OnEvent("Size", ResizeWebView)
        AppGui.OnEvent("Close", CloseApplication)
        AppGui.Show("w760 h680 Center")

        dataDir := A_ScriptDir "\data\WebView2"
        DirCreate(dataDir)

        loaderPath := A_ScriptDir "\..\Lib\" (A_PtrSize * 8) "bit\WebView2Loader.dll"
        if !FileExist(loaderPath)
            throw Error("WebView2Loader.dll을 찾을 수 없습니다: " loaderPath)

        WebViewController := WebView2.create(
            AppGui.Hwnd,
            ,
            0,
            dataDir,
            "",
            0,
            loaderPath
        )
        WebViewController.Fill()
        WebViewController.IsVisible := true

        WebViewCore := WebViewController.CoreWebView2
        WebViewCore.add_WebMessageReceived(OnWebMessageReceived)

        uiFolder := A_ScriptDir "\..\ui"
        DirCreate(SessionService.RootDir())
        WebViewCore.SetVirtualHostNameToFolderMapping("thermal.local", uiFolder, 1)
        WebViewCore.SetVirtualHostNameToFolderMapping("thermal-session.local", SessionService.RootDir(), 1)
        WebViewCore.Navigate("https://thermal.local/index.html")

        OnMessage(WM_DEVICECHANGE, OnDeviceChange)
        SetTimer(InitialDeviceScan, -500)
        WriteAppLog("WebView2와 Vue 화면을 열었습니다.")
    } catch Error as err {
        WriteAppLog("시작 실패: " err.Message)
        MsgBox(
            "프로그램 화면을 시작하지 못했습니다.`n`n" err.Message,
            "열화상 일지",
            "Iconx"
        )
        ExitApp()
    }
}

InitialDeviceScan() {
    ScanCamera("시작 시 검사")
}

OnDeviceChange(wParam, lParam, msg, hwnd) {
    global DBT_DEVICEARRIVAL, DBT_DEVICEREMOVECOMPLETE

    if (wParam = DBT_DEVICEARRIVAL) {
        WriteAppLog("Windows 장치 연결 이벤트를 받았습니다.")
        SetTimer(ScanAfterArrival, -800)
        SetTimer(ScanAfterArrivalConfirmation, -2400)
    } else if (wParam = DBT_DEVICEREMOVECOMPLETE) {
        WriteAppLog("Windows 장치 제거 이벤트를 받았습니다.")
        SetTimer(ScanAfterRemoval, -500)
    }

    return 0
}

ScanAfterArrival() {
    ScanCamera("USB 연결 이벤트")
}

ScanAfterArrivalConfirmation() {
    ScanCamera("USB 연결 확인")
}

ScanAfterRemoval() {
    ScanCamera("USB 제거 이벤트")
}

ScanCamera(reason) {
    global CurrentCamera, CameraWasConnected, LastScanReason

    LastScanReason := reason
    previousSourceKey := CurrentCamera.Has("sourceKey") ? CurrentCamera["sourceKey"] : ""

    try {
        info := DeviceService.FindCamera()
        info := ResolveImageSource(info)
    } catch Error as err {
        WriteAppLog("카메라 검사 실패: " err.Message)
        SendToUi(Map(
            "type", "device-error",
            "message", err.Message,
            "checkedAt", FormatTime(, "HH:mm:ss")
        ))
        return
    }

    CurrentCamera := info
    connected := info["connected"]
    sourceKey := info.Has("sourceKey") ? info["sourceKey"] : ""
    sourceChanged := connected && sourceKey != previousSourceKey

    if (connected && (!CameraWasConnected || sourceChanged)) {
        CameraWasConnected := true
        SendDeviceState()

        if info["isTestSource"] {
            WriteAppLog("디버그 사진자료 사용: " info["imageDir"])
            MsgBox(
                "USB 카메라가 없어 프로젝트의 사진자료 폴더를 사용합니다.`n디버그 작업을 시작합니다.",
                "열화상 일지 · 디버그 모드",
                "Iconi"
            )
        } else {
            WriteAppLog("카메라 연결: " info["model"] " / " info["drive"])
            MsgBox(
                "열화상카메라가 연결되었습니다.`n열화상 일지 작성업무를 시작합니다.",
                "열화상 일지",
                "Iconi"
            )
        }
    } else if (!connected && CameraWasConnected) {
        CameraWasConnected := false
        WriteAppLog("카메라 연결이 해제되었습니다.")
        SendDeviceState()
    } else {
        SendDeviceState()
    }
}

ResolveImageSource(cameraInfo) {
    if cameraInfo["connected"] {
        cameraInfo["isTestSource"] := false
        cameraInfo["sourceKey"] := "usb:" cameraInfo["imageDir"]
        return cameraInfo
    }

    cameraInfo["isTestSource"] := false
    cameraInfo["sourceKey"] := ""

    ; AHK 원본을 편집기에서 실행할 때만 프로젝트 사진자료를 사용한다.
    ; 컴파일된 배포 프로그램은 반드시 실제 USB 카메라가 있어야 한다.
    if A_IsCompiled
        return cameraInfo

    debugImageDir := A_ScriptDir "\..\사진자료"
    if !InStr(FileExist(debugImageDir), "D")
        return cameraInfo

    counts := DeviceService.CountCameraImages(debugImageDir)
    if (counts["completePairs"] = 0)
        return cameraInfo

    return Map(
        "connected", true,
        "isTestSource", true,
        "sourceKey", "debug:" debugImageDir,
        "model", "프로젝트 사진자료",
        "pnpId", "DEBUG_SAMPLE_FOLDER",
        "drive", "",
        "imageDir", debugImageDir,
        "xCount", counts["xCount"],
        "yCount", counts["yCount"],
        "completePairs", counts["completePairs"],
        "incompletePairs", counts["incompletePairs"],
        "detection", "AHK 디버그 사진자료 폴더"
    )
}

OnWebMessageReceived(sender, args) {
    global UiReady

    try {
        message := JSON.parse(args.WebMessageAsJson)
        messageType := message.Has("type") ? message["type"] : ""

        switch messageType {
            case "ui-ready":
                UiReady := true
                WriteAppLog("Vue 화면 준비 완료 메시지를 받았습니다.")
                SendDeviceState()
                SendToUi(Map(
                    "type", "host-ready",
                    "appVersion", "0.1.0-prototype"
                ))
                SetTimer(CheckRecoverableSession, -200)

            case "refresh-device":
                WriteAppLog("화면에서 장치 재검사를 요청했습니다.")
                ScanCamera("사용자 재검사")

            case "open-image-folder":
                OpenImageFolder()

            case "select-template":
                SelectAndAnalyzeTemplate()

            case "confirm-template":
                LoadCameraPhotos()

            case "confirm-matching":
                BeginMarkerSession(message)

            case "marker-add":
                AddCurrentMarker(message)

            case "marker-clear":
                ClearCurrentMarkers()

            case "marker-toggle-preview":
                ToggleMarkerPreview()

            case "marker-save-next":
                SaveCurrentMarkerAndNext()

            case "marker-previous":
                OpenPreviousMarkerItem()

            case "generate-journal":
                GenerateJournal()

            case "open-result-file":
                OpenResultFile()

            case "open-result-folder":
                OpenResultFolder()

            case "new-work":
                StartNewWork()

            default:
                WriteAppLog("알 수 없는 UI 메시지: " messageType)
        }
    } catch Error as err {
        WriteAppLog("UI 메시지 처리 실패: " err.Message)
        SendToUi(Map(
            "type", "notice",
            "level", "error",
            "message", "화면 요청을 처리하지 못했습니다: " err.Message
        ))
    }
}

CheckRecoverableSession() {
    global ResumePromptShown
    if ResumePromptShown
        return
    ResumePromptShown := true

    if SessionService.HasRecoverableSession() {
        answer := MsgBox(
            "작업하다가 도중에 그만둔 임시 작업이 있습니다.`n`n"
            "이어서 작업하시겠습니까?",
            "열화상 일지 · 작업 이어하기",
            "YN Icon?"
        )
        if (answer = "Yes") {
            ResumeMarkerSession()
            return
        }
        try SessionService.Clear()
        catch Error as err
            WriteAppLog("임시 작업 정리 실패: " err.Message)
    } else if SessionService.HasTemporaryFiles() {
        answer := MsgBox(
            "완전한 작업 정보가 없는 임시 파일이 남아 있습니다.`n"
            "임시 파일을 정리하시겠습니까?",
            "열화상 일지 · 임시 파일",
            "YN Icon!"
        )
        if (answer = "Yes")
            try SessionService.Clear()
    }
}

BeginMarkerSession(message) {
    global CurrentTemplate, CurrentPhotos, CurrentCamera, CurrentSession

    if !CurrentTemplate || !CurrentPhotos
        throw Error("양식 또는 사진 검색 정보가 없습니다.")
    if !message.Has("enabledItemIds") || !message.Has("assignments")
        throw Error("사진 매칭 결과가 올바르지 않습니다.")

    if SessionService.HasTemporaryFiles() {
        answer := MsgBox(
            "기존 임시 작업을 지우고 현재 사진 매칭으로 새 작업을 시작하시겠습니까?",
            "열화상 일지",
            "YN Icon?"
        )
        if (answer != "Yes")
            return
    }

    SendToUi(Map("type", "marker-loading", "message", "마커 작업을 준비하고 있습니다."))
    CurrentSession := SessionService.Create(
        CurrentTemplate,
        CurrentPhotos,
        CurrentCamera["imageDir"],
        message["enabledItemIds"],
        message["assignments"]
    )
    WriteAppLog("임시 작업을 만들었습니다: " CurrentSession["items"].Length "개 항목")
    StartMarkerItem(1)
}

ResumeMarkerSession() {
    global CurrentSession
    try {
        CurrentSession := SessionService.Load()
        if CurrentSession.Has("status") && CurrentSession["status"] = "markers-complete" {
            SendToUi(Map(
                "type", "marker-all-complete",
                "completedCount", CurrentSession["items"].Length,
                "message", "이전 작업의 온도마커 처리가 모두 완료되어 있습니다."
            ))
            return
        }
        index := CurrentSession.Has("currentItemIndex") ? CurrentSession["currentItemIndex"] : 1
        if (index < 1 || index > CurrentSession["items"].Length)
            index := 1
        WriteAppLog("임시 작업을 이어서 시작합니다: " index "번째 항목")
        StartMarkerItem(index)
    } catch Error as err {
        WriteAppLog("임시 작업 복구 실패: " err.Message)
        SendToUi(Map("type", "marker-error", "message", "임시 작업을 복구하지 못했습니다: " err.Message))
    }
}

StartMarkerItem(index) {
    global CurrentSession, CurrentGtcState, CurrentMarkerMode

    if !CurrentSession
        throw Error("현재 임시 작업이 없습니다.")
    if (index < 1 || index > CurrentSession["items"].Length)
        throw Error("마커 작업 순서가 올바르지 않습니다.")

    if IsObject(CurrentGtcState)
        GtcService.Close(CurrentGtcState)
    CurrentGtcState := 0
    CurrentSession["currentItemIndex"] := index
    SessionService.Save(CurrentSession)

    item := CurrentSession["items"][index]
    CurrentGtcState := GtcService.Load(item["originalY"])
    CurrentMarkerMode := "thermal"
    RenderCurrentMarkerPreview()
    SendCurrentMarkerState("marker-stage")
    WriteAppLog("마커 작업 항목 열기: " index "/" CurrentSession["items"].Length " " item["label"])
}

AddCurrentMarker(message) {
    global CurrentSession, CurrentGtcState
    if !CurrentSession || !IsObject(CurrentGtcState)
        throw Error("현재 마커 작업 사진이 없습니다.")

    index := CurrentSession["currentItemIndex"]
    item := CurrentSession["items"][index]
    x := message.Has("x") ? message["x"] : -1
    y := message.Has("y") ? message["y"] : -1
    GtcService.AddMarker(CurrentGtcState, item["markers"], x, y)
    item["markerComplete"] := false
    SessionService.Save(CurrentSession)
    RenderCurrentMarkerPreview()
    SendCurrentMarkerState("marker-updated")
}

ClearCurrentMarkers() {
    global CurrentSession
    if !CurrentSession
        return
    item := CurrentSession["items"][CurrentSession["currentItemIndex"]]
    item["markers"] := []
    item["markerComplete"] := false
    SessionService.Save(CurrentSession)
    RenderCurrentMarkerPreview()
    SendCurrentMarkerState("marker-updated")
}

ToggleMarkerPreview() {
    global CurrentMarkerMode
    CurrentMarkerMode := CurrentMarkerMode = "thermal" ? "visible" : "thermal"
    RenderCurrentMarkerPreview()
    SendCurrentMarkerState("marker-updated")
}

SaveCurrentMarkerAndNext() {
    global CurrentSession, CurrentGtcState
    if !CurrentSession || !IsObject(CurrentGtcState)
        throw Error("현재 마커 작업 사진이 없습니다.")

    index := CurrentSession["currentItemIndex"]
    item := CurrentSession["items"][index]
    if !item["markers"].Length {
        SendToUi(Map("type", "notice", "level", "warning", "온도마커를 하나 이상 표시해 주세요."))
        return
    }

    GtcService.SaveOutputs(
        CurrentGtcState,
        item["markers"],
        item["processedX"],
        item["processedY"]
    )
    item["markerComplete"] := true
    SessionService.Save(CurrentSession)
    WriteAppLog("마커 이미지 저장 완료: " index "/" CurrentSession["items"].Length)

    if (index < CurrentSession["items"].Length) {
        StartMarkerItem(index + 1)
        return
    }

    CurrentSession["status"] := "markers-complete"
    SessionService.Save(CurrentSession)
    SendToUi(Map(
        "type", "marker-all-complete",
        "completedCount", CurrentSession["items"].Length,
        "message", "모든 항목의 온도마커 작업이 완료되었습니다."
    ))
}

OpenPreviousMarkerItem() {
    global CurrentSession
    if !CurrentSession
        return
    index := CurrentSession["currentItemIndex"]
    if (index > 1)
        StartMarkerItem(index - 1)
}

RenderCurrentMarkerPreview() {
    global CurrentSession, CurrentGtcState, CurrentMarkerMode, MarkerPreviewVersion
    item := CurrentSession["items"][CurrentSession["currentItemIndex"]]
    previewPath := SessionService.RootDir() "\preview\current.png"
    if FileExist(previewPath)
        FileDelete(previewPath)
    GtcService.RenderPreview(CurrentGtcState, item["markers"], CurrentMarkerMode, previewPath)
    MarkerPreviewVersion += 1
}

SendCurrentMarkerState(messageType) {
    global CurrentSession, CurrentGtcState, CurrentMarkerMode, MarkerPreviewVersion
    index := CurrentSession["currentItemIndex"]
    item := CurrentSession["items"][index]
    SendToUi(Map(
        "type", messageType,
        "itemIndex", index,
        "totalItems", CurrentSession["items"].Length,
        "itemId", item["id"],
        "itemName", item["name"],
        "itemGroup", item["group"],
        "itemLabel", item["label"],
        "baseName", item["baseName"],
        "previewMode", CurrentMarkerMode,
        "previewVersion", MarkerPreviewVersion,
        "markers", item["markers"],
        "minTemperature", GtcService.FormatTemperature(CurrentGtcState.MinTemp),
        "maxTemperature", GtcService.FormatTemperature(CurrentGtcState.MaxTemp),
        "canGoPrevious", index > 1
    ))
}

GenerateJournal() {
    global CurrentSession, CurrentGtcState, ResultDocumentPath

    if !CurrentSession
        CurrentSession := SessionService.Load()
    if !CurrentSession.Has("status") || CurrentSession["status"] != "markers-complete" {
        SendToUi(Map("type", "notice", "level", "warning", "모든 항목의 마커 작업을 먼저 완료해 주세요."))
        return
    }

    templatePath := CurrentSession["templatePath"]
    SplitPath(templatePath, &templateFileName, &templateDir, &templateExtension, &templateName)
    defaultName := templateName "_열화상일지_" FormatTime(, "yyyy-MM-dd") ".hwpx"
    defaultPath := templateDir "\" defaultName

    outputPath := ""
    Loop {
        outputPath := FileSelect(
            "S",
            defaultPath,
            "완성된 열화상 일지 저장",
            "한글 HWPX 문서 (*.hwpx)"
        )
        if (outputPath = "")
            return
        if !RegExMatch(outputPath, "i)\.hwpx$")
            outputPath .= ".hwpx"
        if !FileExist(outputPath)
            break
        MsgBox(
            "같은 이름의 파일이 이미 있습니다.`n다른 파일명을 선택해 주세요.",
            "열화상 일지",
            "Icon!"
        )
        defaultPath := outputPath
    }

    writerPath := A_ScriptDir "\..\tools\hwpx_journal_writer.py"
    if !FileExist(writerPath) {
        SendToUi(Map("type", "journal-error", "message", "HWPX 생성 도구를 찾을 수 없습니다."))
        return
    }
    pythonPath := DocumentService.FindPython()
    if (pythonPath = "") {
        SendToUi(Map("type", "journal-error", "message", "HWPX 생성에 필요한 Python 실행 환경을 찾을 수 없습니다."))
        return
    }

    resultPath := A_Temp "\thermal-journal-result-" A_TickCount ".json"
    sessionPath := SessionService.SessionPath()
    command := '"' pythonPath '" "' writerPath '" --session "' sessionPath
        . '" --output "' outputPath '" --result "' resultPath '"'

    SendToUi(Map("type", "journal-generating", "fileName", defaultName))
    WriteAppLog("결과 HWPX 생성을 시작합니다: " outputPath)

    try {
        exitCode := RunWait(command, A_ScriptDir "\..", "Hide")
        if !FileExist(resultPath)
            throw Error("HWPX 생성 결과 정보를 만들지 못했습니다.")
        result := JSON.parse(FileRead(resultPath, "UTF-8"))
        if (exitCode != 0 || !result.Has("success") || !result["success"])
            throw Error(result.Has("message") ? result["message"] : "HWPX 문서를 만들지 못했습니다.")
        if !FileExist(outputPath)
            throw Error("완성된 HWPX 파일을 찾을 수 없습니다.")

        ResultDocumentPath := outputPath
        if IsObject(CurrentGtcState) {
            GtcService.Close(CurrentGtcState)
            CurrentGtcState := 0
        }

        cleanupWarning := ""
        try SessionService.Clear()
        catch Error as cleanupError {
            cleanupWarning := "완성 문서는 저장했지만 임시 작업 폴더를 정리하지 못했습니다: " cleanupError.Message
            WriteAppLog(cleanupWarning)
        }
        CurrentSession := 0

        SplitPath(outputPath, &resultFileName)
        SendToUi(Map(
            "type", "journal-result",
            "fileName", resultFileName,
            "filePath", outputPath,
            "itemCount", result["itemCount"],
            "imageCount", result["replacedImageCount"],
            "temperatureCount", result["temperatureCount"],
            "cleanupWarning", cleanupWarning
        ))
        WriteAppLog("결과 HWPX 생성 및 검증 완료: " outputPath)
    } catch Error as err {
        WriteAppLog("결과 HWPX 생성 실패: " err.Message)
        SendToUi(Map("type", "journal-error", "message", err.Message))
    } finally {
        if FileExist(resultPath)
            FileDelete(resultPath)
    }
}

OpenResultFile() {
    global ResultDocumentPath
    if (ResultDocumentPath != "" && FileExist(ResultDocumentPath))
        Run(ResultDocumentPath)
}

OpenResultFolder() {
    global ResultDocumentPath
    if (ResultDocumentPath = "" || !FileExist(ResultDocumentPath))
        return
    SplitPath(ResultDocumentPath, , &resultDir)
    Run(resultDir)
}

StartNewWork() {
    global CurrentTemplate, CurrentPhotos, CurrentSession, ResultDocumentPath
    CurrentTemplate := 0
    CurrentPhotos := 0
    CurrentSession := 0
    ResultDocumentPath := ""
    SendToUi(Map("type", "reset-app"))
    ScanCamera("새 작업 시작")
}

LoadCameraPhotos() {
    global CurrentTemplate, CurrentCamera, CurrentPhotos, WebViewCore, AppGui

    if !CurrentTemplate {
        SendToUi(Map("type", "photo-scan-error", "message", "먼저 양식을 선택해 주세요."))
        return
    }

    if !CurrentCamera.Has("connected") || !CurrentCamera["connected"] {
        SendToUi(Map("type", "photo-scan-error", "message", "열화상카메라가 연결되어 있지 않습니다."))
        return
    }

    SendToUi(Map("type", "photo-scan-start"))
    WriteAppLog("카메라 사진 검색을 시작합니다.")

    try {
        previewDir := A_ScriptDir "\..\ui\photo-cache"
        result := ImageService.ScanPairs(
            CurrentCamera["imageDir"],
            CurrentTemplate["itemCount"],
            previewDir
        )
        CurrentPhotos := result

        result["type"] := "photo-scan-result"
        SendToUi(result)
        AppGui.Show("w1280 h820 Center")
        WriteAppLog(
            "카메라 사진 검색 완료: 전체 " result["totalComplete"]
            "쌍 / 자동매칭 후보 " result["suggestedCount"] "쌍"
        )
    } catch Error as err {
        CurrentPhotos := 0
        WriteAppLog("카메라 사진 검색 실패: " err.Message)
        SendToUi(Map("type", "photo-scan-error", "message", err.Message))
    }
}

SelectAndAnalyzeTemplate() {
    global CurrentTemplate

    selectedFile := DocumentService.SelectTemplate()
    if (selectedFile = "")
        return

    SplitPath(selectedFile, &fileName)
    SendToUi(Map(
        "type", "template-analyzing",
        "fileName", fileName
    ))
    WriteAppLog("양식 분석 시작: " selectedFile)

    try {
        result := DocumentService.AnalyzeTemplate(selectedFile)
        CurrentTemplate := result
        result["type"] := "template-result"
        SendToUi(result)
        WriteAppLog("양식 분석 완료: " fileName " / " result["itemCount"] "개 항목")
        LoadCameraPhotos()
    } catch Error as err {
        CurrentTemplate := 0
        WriteAppLog("양식 분석 실패: " err.Message)
        SendToUi(Map(
            "type", "template-error",
            "message", err.Message
        ))
    }
}

SendDeviceState() {
    global CurrentCamera, LastScanReason

    if !CurrentCamera.Has("connected")
        return

    SendToUi(Map(
        "type", "device-state",
        "connected", CurrentCamera["connected"],
        "isTestSource", CurrentCamera.Has("isTestSource") ? CurrentCamera["isTestSource"] : false,
        "model", CurrentCamera.Has("model") ? CurrentCamera["model"] : "",
        "drive", CurrentCamera.Has("drive") ? CurrentCamera["drive"] : "",
        "imageDir", CurrentCamera.Has("imageDir") ? CurrentCamera["imageDir"] : "",
        "xCount", CurrentCamera.Has("xCount") ? CurrentCamera["xCount"] : 0,
        "yCount", CurrentCamera.Has("yCount") ? CurrentCamera["yCount"] : 0,
        "completePairs", CurrentCamera.Has("completePairs") ? CurrentCamera["completePairs"] : 0,
        "incompletePairs", CurrentCamera.Has("incompletePairs") ? CurrentCamera["incompletePairs"] : 0,
        "detection", CurrentCamera.Has("detection") ? CurrentCamera["detection"] : "",
        "reason", LastScanReason,
        "checkedAt", FormatTime(, "HH:mm:ss")
    ))
}

SendToUi(payload) {
    global UiReady, WebViewCore

    if (!UiReady || !WebViewCore)
        return

    try WebViewCore.PostWebMessageAsJson(JSON.stringify(payload))
    catch Error as err
        WriteAppLog("Vue 상태 전송 실패: " err.Message)
}

OpenImageFolder() {
    global CurrentCamera

    if CurrentCamera.Has("connected")
        && CurrentCamera["connected"]
        && CurrentCamera.Has("imageDir")
        && InStr(FileExist(CurrentCamera["imageDir"]), "D") {
        Run(CurrentCamera["imageDir"])
        return
    }

    SendToUi(Map(
        "type", "notice",
        "level", "warning",
        "message", "현재 열 수 있는 카메라 IMAGE 폴더가 없습니다."
    ))
}

ResizeWebView(guiObj, minMax, width, height) {
    global WebViewController

    if (minMax = -1 || !WebViewController)
        return

    try WebViewController.Fill()
}

CloseApplication(*) {
    global WebViewController, CurrentGtcState

    WriteAppLog("프로그램을 종료합니다.")
    if IsObject(CurrentGtcState)
        try GtcService.Close(CurrentGtcState)
    GtcService.Shutdown()
    try WebViewController.Close()
    ExitApp()
}

WriteAppLog(message) {
    try {
        logDir := A_ScriptDir "\logs"
        DirCreate(logDir)
        FileAppend(
            FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`r`n",
            logDir "\app.log",
            "UTF-8"
        )
    }
}

