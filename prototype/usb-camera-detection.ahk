#Requires AutoHotkey v2.0
#SingleInstance Force

; BOSCH GTC400C USB detection prototype.
; - Detects a camera that was connected before the program starts.
; - Re-scans after Windows device arrival/removal events.
; - Never writes to the camera drive.

global WM_DEVICECHANGE := 0x0219
global DBT_DEVICEARRIVAL := 0x8000
global DBT_DEVICEREMOVECOMPLETE := 0x8004

global CameraWasConnected := false
global InitialScanFinished := false
global LastCameraSignature := ""
global LastEventText := "프로그램 시작"

global MainGui := Gui(, "열화상카메라 USB 인식 테스트")
MainGui.SetFont("s10", "맑은 고딕")
MainGui.MarginX := 20
MainGui.MarginY := 18

MainGui.AddText("xm w540 Center", "BOSCH GTC400C 연결 상태")
global StatusText := MainGui.AddText("xm y+10 w540 h38 Center cC0392B", "검사 준비 중")
StatusText.SetFont("s15 Bold")

global DetailText := MainGui.AddText("xm y+8 w540 h105", "장치 정보를 확인하고 있습니다.")

global ScanButton := MainGui.AddButton("xm y+10 w165 h34 Default", "현재 상태 다시 검사")
ScanButton.OnEvent("Click", (*) => ScanCamera("수동 검사"))

global OpenImageButton := MainGui.AddButton("x+10 yp w165 h34 Disabled", "IMAGE 폴더 열기")
OpenImageButton.OnEvent("Click", (*) => OpenCameraImageFolder())

global ExitButton := MainGui.AddButton("x+10 yp w165 h34", "테스트 종료")
ExitButton.OnEvent("Click", (*) => ExitApp())

MainGui.AddText("xm y+14 w540", "이벤트 기록")
global LogBox := MainGui.AddEdit("xm y+5 w540 h145 ReadOnly -Wrap")

MainGui.OnEvent("Close", (*) => ExitApp())
MainGui.Show("w580 h420")

OnMessage(WM_DEVICECHANGE, WM_DEVICECHANGE_Handler)
AppendLog("USB 감지 프로토타입을 시작했습니다.")

; Let the GUI finish drawing before the first WMI scan and message box.
SetTimer(InitialCameraScan, -350)

InitialCameraScan() {
    ScanCamera("시작 시 검사")
}

WM_DEVICECHANGE_Handler(wParam, lParam, msg, hwnd) {
    global DBT_DEVICEARRIVAL, DBT_DEVICEREMOVECOMPLETE, LastEventText

    if (wParam = DBT_DEVICEARRIVAL) {
        LastEventText := "Windows 장치 연결 이벤트"
        AppendLog("장치 연결 이벤트 수신 - 드라이브 할당을 기다린 후 검사합니다.")
        SetTimer(ScanAfterArrival, -800)
        SetTimer(ScanAfterArrivalAgain, -2400)
    } else if (wParam = DBT_DEVICEREMOVECOMPLETE) {
        LastEventText := "Windows 장치 제거 이벤트"
        AppendLog("장치 제거 이벤트 수신 - 연결 상태를 다시 검사합니다.")
        SetTimer(ScanAfterRemoval, -500)
    }

    return 0
}

ScanAfterArrival() {
    ScanCamera("연결 이벤트 1차 검사")
}

ScanAfterArrivalAgain() {
    ScanCamera("연결 이벤트 확인 검사")
}

ScanAfterRemoval() {
    ScanCamera("제거 이벤트 검사")
}

ScanCamera(reason) {
    global CameraWasConnected, InitialScanFinished, LastCameraSignature

    try {
        info := FindBoschCamera()
    } catch Error as err {
        UpdateErrorState(err.Message)
        AppendLog(reason " 실패: " err.Message)
        InitialScanFinished := true
        return
    }

    connected := info["connected"]
    signature := connected
        ? info["pnpId"] "|" info["drive"]
        : ""

    UpdateStatus(info, reason)

    if connected {
        if !CameraWasConnected {
            AppendLog("카메라 연결 확인: " info["model"] " / " info["drive"])
            CameraWasConnected := true
            LastCameraSignature := signature

            MsgBox(
                "열화상카메라가 연결되었습니다.`n열화상 일지 작성업무를 시작합니다.",
                "열화상 일지",
                "Iconi"
            )
        } else if (signature != LastCameraSignature) {
            AppendLog("카메라 연결 정보 변경: " signature)
            LastCameraSignature := signature
        }
    } else {
        if CameraWasConnected
            AppendLog("열화상카메라 연결이 해제되었습니다.")

        CameraWasConnected := false
        LastCameraSignature := ""
    }

    InitialScanFinished := true
}

FindBoschCamera() {
    wmi := ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
    disks := wmi.ExecQuery(
        "SELECT Index, DeviceID, Model, PNPDeviceID, InterfaceType "
        . "FROM Win32_DiskDrive WHERE InterfaceType='USB'"
    )

    for disk in disks {
        model := SafeText(disk.Model)
        pnpId := SafeText(disk.PNPDeviceID)
        upperModel := StrUpper(model)
        upperPnpId := StrUpper(pnpId)

        isBoschGtc400c := InStr(upperModel, "BOSCH GTC400C")
            || InStr(upperPnpId, "VEN_BOSCH&PROD_GTC400C")

        if !isBoschGtc400c
            continue

        drive := FindLogicalDriveForDisk(wmi, disk.Index)
        if (drive = "")
            drive := FindDriveByCameraFolder()

        imageDir := (drive != "") ? drive "\IMAGE" : ""
        counts := CountCameraImages(imageDir)

        return Map(
            "connected", true,
            "model", model,
            "pnpId", pnpId,
            "drive", drive,
            "imageDir", imageDir,
            "xCount", counts["xCount"],
            "yCount", counts["yCount"],
            "completePairs", counts["completePairs"],
            "incompletePairs", counts["incompletePairs"],
            "detection", "USB 디스크 모델"
        )
    }

    ; Fallback for systems where WMI returns the volume before the disk model.
    fallbackDrive := FindDriveByCameraFolder()
    if (fallbackDrive != "") {
        imageDir := fallbackDrive "\IMAGE"
        counts := CountCameraImages(imageDir)
        return Map(
            "connected", true,
            "model", "BOSCH GTC400C 추정",
            "pnpId", "WMI 장치 ID 확인 전",
            "drive", fallbackDrive,
            "imageDir", imageDir,
            "xCount", counts["xCount"],
            "yCount", counts["yCount"],
            "completePairs", counts["completePairs"],
            "incompletePairs", counts["incompletePairs"],
            "detection", "IMAGE 폴더와 X/Y 파일 구조"
        )
    }

    return Map(
        "connected", false,
        "model", "",
        "pnpId", "",
        "drive", "",
        "imageDir", "",
        "xCount", 0,
        "yCount", 0,
        "completePairs", 0,
        "incompletePairs", 0,
        "detection", ""
    )
}

FindLogicalDriveForDisk(wmi, diskIndex) {
    partitions := wmi.ExecQuery(
        "SELECT DeviceID FROM Win32_DiskPartition WHERE DiskIndex=" diskIndex
    )

    for partition in partitions {
        partitionId := StrReplace(SafeText(partition.DeviceID), "'", "''")
        query := "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='" partitionId "'} "
            . "WHERE AssocClass=Win32_LogicalDiskToPartition"

        for logicalDisk in wmi.ExecQuery(query) {
            drive := SafeText(logicalDisk.DeviceID)
            if (drive != "")
                return drive
        }
    }

    return ""
}

FindDriveByCameraFolder() {
    for driveLetter in StrSplit(DriveGetList("REMOVABLE")) {
        drive := driveLetter ":"
        imageDir := drive "\IMAGE"
        if !InStr(FileExist(imageDir), "D")
            continue

        hasX := false
        hasY := false

        Loop Files imageDir "\*.JPG", "F" {
            if RegExMatch(A_LoopFileName, "i)X\.JPG$")
                hasX := true
            else if RegExMatch(A_LoopFileName, "i)Y\.JPG$")
                hasY := true

            if (hasX && hasY)
                return drive
        }
    }

    return ""
}

CountCameraImages(imageDir) {
    result := Map(
        "xCount", 0,
        "yCount", 0,
        "completePairs", 0,
        "incompletePairs", 0
    )

    if (imageDir = "" || !InStr(FileExist(imageDir), "D"))
        return result

    pairs := Map()

    Loop Files imageDir "\*.JPG", "F" {
        if !RegExMatch(A_LoopFileName, "i)^(.*?)(X|Y)\.JPG$", &match)
            continue

        baseName := StrUpper(match[1])
        kind := StrUpper(match[2])

        if !pairs.Has(baseName)
            pairs[baseName] := Map("X", false, "Y", false)

        pairs[baseName][kind] := true
        result[kind = "X" ? "xCount" : "yCount"] += 1
    }

    for baseName, pair in pairs {
        if (pair["X"] && pair["Y"])
            result["completePairs"] += 1
        else
            result["incompletePairs"] += 1
    }

    return result
}

UpdateStatus(info, reason) {
    global StatusText, DetailText, OpenImageButton

    if info["connected"] {
        StatusText.Text := "● 열화상카메라 연결됨"
        StatusText.SetFont("s15 Bold c16833D")

        driveText := info["drive"] != "" ? info["drive"] : "드라이브 할당 대기 중"
        DetailText.Text := "장치: " info["model"]
            . "`n드라이브: " driveText
            . "`n사진 폴더: " (info["imageDir"] != "" ? info["imageDir"] : "확인 중")
            . "`nX/Y 이미지: " info["xCount"] " / " info["yCount"]
            . "    완전한 쌍: " info["completePairs"]
            . "    불완전: " info["incompletePairs"]
            . "`n식별 방식: " info["detection"] "    최근 검사: " reason

        if (info["imageDir"] != "" && InStr(FileExist(info["imageDir"]), "D"))
            OpenImageButton.Enabled := true
        else
            OpenImageButton.Enabled := false
    } else {
        StatusText.Text := "○ 열화상카메라 연결 대기 중"
        StatusText.SetFont("s15 Bold cC0392B")
        DetailText.Text := "BOSCH GTC400C를 USB로 연결해 주세요."
            . "`n연결되면 프로그램이 자동으로 다시 검사합니다."
            . "`n`n최근 검사: " reason
        OpenImageButton.Enabled := false
    }
}

UpdateErrorState(message) {
    global StatusText, DetailText, OpenImageButton
    StatusText.Text := "! USB 검사 오류"
    StatusText.SetFont("s15 Bold cC0392B")
    DetailText.Text := "장치 정보를 확인하지 못했습니다.`n" message
    OpenImageButton.Enabled := false
}

OpenCameraImageFolder() {
    info := FindBoschCamera()
    if (info["connected"] && info["imageDir"] != "" && InStr(FileExist(info["imageDir"]), "D"))
        Run(info["imageDir"])
    else
        MsgBox("현재 열 수 있는 카메라 IMAGE 폴더가 없습니다.", "열화상카메라", "Icon!")
}

AppendLog(message) {
    global LogBox
    timestamp := FormatTime(, "HH:mm:ss")
    line := "[" timestamp "] " message

    if (LogBox.Value = "")
        LogBox.Value := line
    else
        LogBox.Value .= "`r`n" line

    SendMessage(0x0115, 7, 0, LogBox.Hwnd) ; WM_VSCROLL / SB_BOTTOM

    try {
        logDir := A_ScriptDir "\logs"
        DirCreate(logDir)
        FileAppend(
            FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`r`n",
            logDir "\usb-detection.log",
            "UTF-8"
        )
    }
}

SafeText(value) {
    try
        return value ""
    catch
        return ""
}

