#Requires AutoHotkey v2.0
#SingleInstance Force
#Include <Gdip_All>

; Bosch GTC 400C radiometric JPEG prototype.
; This script must run with 32-bit AutoHotkey because Bosch.GTC.CppWrapper.dll is 32-bit.

global GtcState := 0
global MarkerList := []
global MainGui := 0
global ThermalPicture := 0
global StatusText := 0
global GdipToken := 0
global PreviewMode := "thermal"

if (A_PtrSize != 4) {
    MsgBox "이 프로토타입은 32비트 AutoHotkey로 실행하거나 컴파일해야 합니다.`n현재 포인터 크기: " A_PtrSize * 8 "비트", "GTC 온도마커", "Iconx"
    ExitApp
}

try {
    if (A_Args.Length >= 1 && (A_Args[1] = "--self-test" || A_Args[1] = "--render-test")) {
        testMode := A_Args[1]
        testFile := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\청사전기실\RB02110Y.JPG"
        state := LoadGtcTemperatureData(testFile)
        sampleTemp := TemperatureAt(state, 160, 120)
        FileAppend(
            "model=" state.Model "`n"
            "size=" state.Width "x" state.Height "`n"
            "min=" Format("{:.2f}", state.MinTemp) "`n"
            "max=" Format("{:.2f}", state.MaxTemp) "`n"
            "emissivity=" Format("{:.2f}", state.Emissivity) "`n"
            "reflected=" Format("{:.2f}", state.ReflectedTemp) "`n"
            "crop=" state.ThermalCropX "," state.ThermalCropY "," state.ThermalCropWidth "," state.ThermalCropHeight "`n"
            "visible_transform=" Format("{:.6f}", state.VisibleScale) "," state.VisibleShiftX "," state.VisibleShiftY "`n"
            "thermal_window_step=" state.ThermalWindowStep "`n"
            "temp_160_120=" Format("{:.5f}", sampleTemp) "`n",
            "*"
        )

        if (testMode = "--render-test") {
            outputPath := A_Args.Length >= 3 ? A_Args[3] : A_ScriptDir "\prototype_output\render-test.png"
            SplitPath outputPath, , &outputDirectory
            if outputDirectory
                DirCreate outputDirectory
            GtcState := state
            MarkerList := [{X: 160, Y: 120, Temp: sampleTemp}]
            GdipToken := Gdip_Startup()
            if !GdipToken
                throw Error("GDI+ 초기화에 실패했습니다.")
            bitmap := BuildMarkedBitmap("thermal", true)
            saveResult := Gdip_SaveBitmapToFile(bitmap, outputPath, 100)
            Gdip_DisposeImage(bitmap)
            if (saveResult != 0)
                throw Error("열화상 렌더링 테스트 저장 실패. GDI+ 오류: " saveResult)

            SplitPath outputPath, , &testOutputDirectory, &testOutputExtension, &testOutputName
            visibleTestPath := testOutputDirectory "\" testOutputName "_visible." testOutputExtension
            visibleBitmap := BuildMarkedBitmap("visible", true)
            visibleSaveResult := Gdip_SaveBitmapToFile(visibleBitmap, visibleTestPath, 100)
            Gdip_DisposeImage(visibleBitmap)
            if (visibleSaveResult != 0)
                throw Error("실화상 렌더링 테스트 저장 실패. GDI+ 오류: " visibleSaveResult)
            FileAppend("thermal_rendered=" outputPath "`nvisible_rendered=" visibleTestPath "`n", "*")

            ; Verify the same HBITMAP path used by the visible GUI.
            testGui := Gui()
            testPicture := testGui.AddPicture("w480 h360 Border +0x100", state.YPath)
            testBitmap := BuildMarkedBitmap("thermal")
            testHBitmap := Gdip_CreateHBITMAPFromBitmap(testBitmap)
            Gdip_DisposeImage(testBitmap)
            SetImage(testPicture.Hwnd, testHBitmap)
            controlStyle := DllCall("user32\GetWindowLongW", "Ptr", testPicture.Hwnd, "Int", -16, "UInt")
            assignedBitmap := DllCall("user32\SendMessageW", "Ptr", testPicture.Hwnd, "UInt", 0x173, "Ptr", 0, "Ptr", 0, "Ptr")
            FileAppend("picture_style=" Format("0x{:X}", controlStyle & 0x1F) "`npicture_hbitmap=" assignedBitmap "`n", "*")
            if ((controlStyle & 0x1F) != 0x0E || !assignedBitmap)
                throw Error("Picture 컨트롤 비트맵 연결 검증에 실패했습니다.")
            SetImage(testPicture.Hwnd, 0)
            testGui.Destroy()
            Gdip_Shutdown(GdipToken)
            GdipToken := 0
        }
        DllCall("kernel32\FreeLibrary", "Ptr", state.DllHandle)
        ExitApp
    }

    selectedY := FileSelect(3, A_ScriptDir, "온도 데이터가 포함된 Y.JPG 선택", "JPEG 이미지 (*.jpg; *.jpeg)")
    if !selectedY
        ExitApp

    GtcState := LoadGtcTemperatureData(selectedY)
    StartMarkerGui()
} catch as err {
    MsgBox err.Message, "GTC 온도마커 오류", "Iconx"
    ExitApp
}

LoadGtcTemperatureData(yPath) {
    file := FileOpen(yPath, "r")
    if !IsObject(file)
        throw Error("파일을 열 수 없습니다:`n" yPath)

    jpeg := Buffer(file.Length, 0)
    bytesRead := file.RawRead(jpeg)
    file.Close()
    if (bytesRead != jpeg.Size)
        throw Error("JPEG 파일을 끝까지 읽지 못했습니다.")

    section := FindGtcApp15(jpeg)
    model := ReadAsciiZ(jpeg, section.ModelOffset, 19)
    if !InStr(model, "GTC_400")
        throw Error("현재 프로토타입은 GTC 400 계열만 지원합니다.`n감지된 모델: " model)

    rawWidth := 160
    rawHeight := 120
    rawCount := rawWidth * rawHeight
    rawByteLength := rawCount * 2
    rawOffset := section.ModelOffset + 24
    metaOffset := rawOffset + rawByteLength

    if (metaOffset + 84 > section.EndOffset)
        throw Error("APP15 열화상 데이터 길이가 예상보다 짧습니다.")

    rawDoubles := Buffer(rawCount * 8, 0)
    Loop rawCount {
        sourceOffset := rawOffset + (A_Index - 1) * 2
        NumPut("Double", NumGet(jpeg, sourceOffset, "UShort"), rawDoubles, (A_Index - 1) * 8)
    }

    minTemp := NumGet(jpeg, metaOffset, "Float")
    maxTemp := NumGet(jpeg, metaOffset + 4, "Float")
    palette := NumGet(jpeg, metaOffset + 12, "UChar")
    opacity := Round(NumGet(jpeg, metaOffset + 18, "UChar") * 100 / 255)
    reflectedTemp := NumGet(jpeg, metaOffset + 24, "Float")
    emissivity := NumGet(jpeg, metaOffset + 32, "Float")
    visibleShiftX := NumGet(jpeg, metaOffset + 40, "Short")
    visibleShiftY := NumGet(jpeg, metaOffset + 42, "Short")
    visibleScale := NumGet(jpeg, metaOffset + 48, "Float")
    thermalWindowStep := NumGet(jpeg, metaOffset + 52, "UChar")

    appDir := A_ScriptDir "\Application"
    dllPath := appDir "\Bosch.GTC.CppWrapper.dll"
    if !FileExist(dllPath)
        throw Error("GTC 계산 DLL이 없습니다:`n" dllPath)

    ; OpenCV dependencies reside next to the Bosch DLL.
    DllCall("kernel32\SetDllDirectoryW", "Str", appDir, "Int")
    dllHandle := DllCall("kernel32\LoadLibraryW", "Str", dllPath, "Ptr")
    if !dllHandle
        throw Error("Bosch.GTC.CppWrapper.dll 로드 실패.`nWindows 오류: " A_LastError)

    try {
        pInit := GetDllProc(dllHandle, "OpenCVInitFn")
        pGetScale := GetDllProc(dllHandle, "GetTemperatureScale")
        pColorize := GetDllProc(dllHandle, "TemperatureScaleChange")

        ; Parameters verified against Bosch.GTC.Model 1.7.2:
        ; data, emissivity, reflected temperature, thermal-window step,
        ; opacity, palette, device index.
        DllCall(pInit,
            "Ptr", rawDoubles.Ptr,
            "Double", emissivity,
            "Double", reflectedTemp,
            "Int", thermalWindowStep,
            "Int", opacity,
            "Int", palette,
            "Int", 0,
            "CDecl")

        width := 480
        height := 360
        temperatures := Buffer(width * height * 8, 0)
        minMax := Buffer(2 * 8, 0)
        DllCall(pGetScale, "Ptr", minMax.Ptr, "Ptr", temperatures.Ptr, "CDecl")

        calculatedMin := NumGet(minMax, 0, "Double")
        calculatedMax := NumGet(minMax, 8, "Double")
        if (calculatedMin > -273)
            minTemp := calculatedMin
        if (calculatedMax > -273)
            maxTemp := calculatedMax

        thermalCrop := FindValidTemperatureBounds(temperatures, width, height)

        ; Generate a clean thermal image and its 1,024-step palette directly
        ; from the radiometric data.  These buffers contain no hot/cold/center
        ; markers; those markers only existed in the camera-rendered X.JPG.
        thermalPixels := Buffer(width * height * 4, 0)
        spectrumPixels := Buffer(1024 * 4, 0)
        DllCall(pColorize,
            "Double", minTemp,
            "Double", maxTemp,
            "Ptr", temperatures.Ptr,
            "Ptr", thermalPixels.Ptr,
            "Int", palette,
            "Double", minTemp,
            "Double", maxTemp,
            "Ptr", spectrumPixels.Ptr,
            "Int", 0,
            "UChar", 0,
            "CDecl")

        ; TemperatureScaleChange marks invalid border pixels transparent.
        ; For a thermal-only export we keep their palette colour and make the
        ; complete 480x360 frame opaque, matching GTC's thermal export.
        thermalOpaquePixels := Buffer(width * height * 4, 0)
        DllCall("ntdll\RtlMoveMemory", "Ptr", thermalOpaquePixels.Ptr, "Ptr", thermalPixels.Ptr, "UPtr", thermalPixels.Size)
        Loop width * height
            NumPut("UChar", 255, thermalOpaquePixels, (A_Index - 1) * 4 + 3)

        xPath := PairedThermalPath(yPath)

        return {
            YPath: yPath,
            XPath: xPath,
            Model: model,
            Width: width,
            Height: height,
            Temperatures: temperatures,
            ThermalPixels: thermalPixels,
            ThermalOpaquePixels: thermalOpaquePixels,
            SpectrumPixels: spectrumPixels,
            ThermalCropX: thermalCrop.X,
            ThermalCropY: thermalCrop.Y,
            ThermalCropWidth: thermalCrop.Width,
            ThermalCropHeight: thermalCrop.Height,
            VisibleScale: visibleScale,
            VisibleShiftX: visibleShiftX,
            VisibleShiftY: visibleShiftY,
            ThermalWindowStep: thermalWindowStep,
            MinTemp: minTemp,
            MaxTemp: maxTemp,
            Emissivity: emissivity,
            ReflectedTemp: reflectedTemp,
            DllHandle: dllHandle
        }
    } catch {
        DllCall("kernel32\FreeLibrary", "Ptr", dllHandle)
        throw
    }
}

FindValidTemperatureBounds(temperatures, width, height) {
    left := width
    top := height
    right := -1
    bottom := -1

    Loop height {
        y := A_Index - 1
        Loop width {
            x := A_Index - 1
            temperature := NumGet(temperatures, (y * width + x) * 8, "Double")
            if (temperature > -273) {
                left := Min(left, x)
                top := Min(top, y)
                right := Max(right, x)
                bottom := Max(bottom, y)
            }
        }
    }

    if (right < left || bottom < top)
        throw Error("유효한 열화상 영역을 찾지 못했습니다.")
    return {X: left, Y: top, Width: right - left + 1, Height: bottom - top + 1}
}

FindGtcApp15(jpeg) {
    if (jpeg.Size < 4 || NumGet(jpeg, 0, "UChar") != 0xFF || NumGet(jpeg, 1, "UChar") != 0xD8)
        throw Error("유효한 JPEG 파일이 아닙니다.")

    pos := 2
    while (pos + 4 <= jpeg.Size) {
        if (NumGet(jpeg, pos, "UChar") != 0xFF)
            throw Error("JPEG 마커 구조가 올바르지 않습니다. 위치: " pos)

        marker := NumGet(jpeg, pos + 1, "UChar")
        if (marker = 0xD9 || marker = 0xDA)
            break

        segmentLength := (NumGet(jpeg, pos + 2, "UChar") << 8)
            | NumGet(jpeg, pos + 3, "UChar")
        if (segmentLength < 2 || pos + 2 + segmentLength > jpeg.Size)
            throw Error("손상된 JPEG 세그먼트입니다. 위치: " pos)

        payloadOffset := pos + 4
        payloadLength := segmentLength - 2
        if (marker = 0xEF) {
            modelOffset := FindAscii(jpeg, payloadOffset, Min(payloadLength, 64), "GTC_")
            if (modelOffset >= 0)
                return {ModelOffset: modelOffset, EndOffset: payloadOffset + payloadLength}
        }
        pos += 2 + segmentLength
    }
    throw Error("GTC 방사측정 APP15 데이터가 없습니다.`n원본 Y.JPG를 선택했는지 확인하세요.")
}

FindAscii(buffer, startOffset, searchLength, needle) {
    needleLength := StrLen(needle)
    lastOffset := startOffset + searchLength - needleLength
    pos := startOffset
    while (pos <= lastOffset) {
        matched := true
        charIndex := 1
        while (charIndex <= needleLength) {
            if (NumGet(buffer, pos + charIndex - 1, "UChar") != Ord(SubStr(needle, charIndex, 1))) {
                matched := false
                break
            }
            charIndex += 1
        }
        if matched
            return pos
        pos += 1
    }
    return -1
}

ReadAsciiZ(buffer, offset, maxLength) {
    result := ""
    Loop maxLength {
        value := NumGet(buffer, offset + A_Index - 1, "UChar")
        if (value = 0)
            break
        result .= Chr(value)
    }
    return result
}

GetDllProc(dllHandle, procName) {
    address := DllCall("kernel32\GetProcAddress", "Ptr", dllHandle, "AStr", procName, "Ptr")
    if !address
        throw Error("DLL 함수 주소를 찾지 못했습니다: " procName)
    return address
}

PairedThermalPath(yPath) {
    SplitPath yPath, &fileName, &directory, &extension, &nameNoExt
    if !RegExMatch(nameNoExt, "i)Y$")
        throw Error("선택 파일명이 Y로 끝나지 않습니다:`n" fileName)
    thermalName := RegExReplace(nameNoExt, "i)Y$", "X")
    return directory "\" thermalName "." extension
}

TemperatureAt(state, x, y) {
    if (x < 0 || y < 0 || x >= state.Width || y >= state.Height)
        throw Error("온도 좌표가 범위를 벗어났습니다.")
    return NumGet(state.Temperatures, (y * state.Width + x) * 8, "Double")
}

FormatGtcTemperature(value) {
    ; .NET Math.Round uses midpoint-to-even. GTC therefore shows 31.65 as
    ; 31.6, while AutoHotkey's Format would show 31.7.
    sign := value < 0 ? -1 : 1
    scaled := Abs(value) * 10
    whole := Floor(scaled)
    fraction := scaled - whole
    if (Abs(fraction - 0.5) < 0.000001)
        rounded := Mod(whole, 2) = 0 ? whole : whole + 1
    else
        rounded := Round(scaled)
    return Format("{:.1f}", sign * rounded / 10)
}

StartMarkerGui() {
    global GtcState, MarkerList, MainGui, ThermalPicture, StatusText, GdipToken

    GdipToken := Gdip_Startup()
    if !GdipToken
        throw Error("GDI+ 초기화에 실패했습니다.")

    MainGui := Gui("-MaximizeBox", "GTC 온도마커 32비트 프로토타입")
    MainGui.MarginX := 10
    MainGui.MarginY := 10
    ; Supplying the JPEG during control creation makes AutoHotkey create an
    ; SS_BITMAP static control.  Creating an empty Picture control can leave it
    ; in icon mode, in which case STM_SETIMAGE accepts our HBITMAP but draws
    ; nothing on some systems.
    ThermalPicture := MainGui.AddPicture("w480 h360 Border +0x100", GtcState.YPath)
    ThermalPicture.OnEvent("Click", OnThermalClick)

    clearButton := MainGui.AddButton("xm y+10 w90", "마커 지우기")
    clearButton.OnEvent("Click", ClearMarkers)
    previewButton := MainGui.AddButton("x+8 yp w100", "실화상 보기")
    previewButton.OnEvent("Click", TogglePreview)
    saveButton := MainGui.AddButton("x+8 yp w90 Default", "X/Y 저장")
    saveButton.OnEvent("Click", SaveMarkedImage)
    StatusText := MainGui.AddText("x+12 yp+5 w170", "이미지를 클릭해 마커를 추가하세요.")

    info := "모델: " GtcState.Model
    info .= "    범위: " Format("{:.2f}", GtcState.MinTemp) " ~ " Format("{:.2f}", GtcState.MaxTemp) " °C"
    info .= "    방사율: " Format("{:.2f}", GtcState.Emissivity)
    MainGui.AddText("xm y+12 w480", info)
    MainGui.OnEvent("Close", (*) => ExitApp())
    OnExit CleanupPrototype

    UpdatePreview()
    MainGui.Show("AutoSize")
}

OnThermalClick(control, *) {
    global GtcState, MarkerList, ThermalPicture, StatusText

    CoordMode "Mouse", "Client"
    MouseGetPos &mouseX, &mouseY, &windowHwnd, &controlHwnd, 2
    ThermalPicture.GetPos &pictureX, &pictureY, &pictureWidth, &pictureHeight
    displayX := Max(0, Min(GtcState.Width - 1,
        Round((mouseX - pictureX) * (GtcState.Width - 1) / (pictureWidth - 1))))
    displayY := Max(0, Min(GtcState.Height - 1,
        Round((mouseY - pictureY) * (GtcState.Height - 1) / (pictureHeight - 1))))
    x := GtcState.ThermalCropX + Round(displayX * (GtcState.ThermalCropWidth - 1) / (GtcState.Width - 1))
    y := GtcState.ThermalCropY + Round(displayY * (GtcState.ThermalCropHeight - 1) / (GtcState.Height - 1))

    temperature := TemperatureAt(GtcState, x, y)
    if (temperature <= -273) {
        StatusText.Text := "유효 온도 영역 밖입니다. 다른 지점을 클릭하세요."
        SoundBeep 900, 100
        return
    }

    MarkerList.Push({X: x, Y: y, Temp: temperature})
    StatusText.Text := "마커 " MarkerList.Length ": " FormatGtcTemperature(temperature) " °C"
    UpdatePreview()
}

ClearMarkers(*) {
    global MarkerList, StatusText
    MarkerList := []
    StatusText.Text := "모든 마커를 지웠습니다."
    UpdatePreview()
}

TogglePreview(button, *) {
    global PreviewMode, StatusText
    if (PreviewMode = "thermal") {
        PreviewMode := "visible"
        button.Text := "열화상 보기"
        StatusText.Text := "실화상 미리보기"
    } else {
        PreviewMode := "thermal"
        button.Text := "실화상 보기"
        StatusText.Text := "열화상 미리보기"
    }
    UpdatePreview()
}

UpdatePreview() {
    global ThermalPicture, PreviewMode
    bitmap := BuildMarkedBitmap(PreviewMode)
    hBitmap := Gdip_CreateHBITMAPFromBitmap(bitmap)
    Gdip_DisposeImage(bitmap)
    if !hBitmap
        throw Error("미리보기 비트맵 생성에 실패했습니다.")
    SetImage(ThermalPicture.Hwnd, hBitmap)
}

BuildMarkedBitmap(imageKind := "thermal", includeLegend := false) {
    global GtcState, MarkerList

    mainWidth := GtcState.Width
    mainHeight := includeLegend ? 370 : GtcState.Height
    canvasWidth := includeLegend ? 536 : mainWidth

    canvas := Gdip_CreateBitmap(canvasWidth, mainHeight)
    graphics := Gdip_GraphicsFromImage(canvas)
    Gdip_GraphicsClear(graphics, 0xFFFFFFFF)
    Gdip_SetInterpolationMode(graphics, 7)

    if (imageKind = "thermal") {
        ; Build the same registered real-image canvas used by GTC, crop it to
        ; the thermal field of view, then overlay thermal at 70% opacity.
        ; The resulting X export is thermal 70% + real image 30%.
        visibleAligned := CreateAlignedVisibleBitmap()
        Gdip_DrawImage(graphics, visibleAligned, 0, 0, mainWidth, mainHeight,
            GtcState.ThermalCropX, GtcState.ThermalCropY,
            GtcState.ThermalCropWidth, GtcState.ThermalCropHeight)
        Gdip_DisposeImage(visibleAligned)

        thermalSource := CreateBgraBitmap(GtcState.ThermalOpaquePixels, GtcState.Width, GtcState.Height)
        if !thermalSource {
            Gdip_DeleteGraphics(graphics)
            Gdip_DisposeImage(canvas)
            throw Error("DLL 열화상 비트맵 생성에 실패했습니다.")
        }
        Gdip_DrawImage(graphics, thermalSource, 0, 0, mainWidth, mainHeight,
            GtcState.ThermalCropX, GtcState.ThermalCropY,
            GtcState.ThermalCropWidth, GtcState.ThermalCropHeight, 0.70)
        Gdip_DisposeImage(thermalSource)
    } else if (imageKind = "visible") {
        visibleSource := Gdip_CreateBitmapFromFile(GtcState.YPath)
        if !visibleSource {
            Gdip_DeleteGraphics(graphics)
            Gdip_DisposeImage(canvas)
            throw Error("실화상 이미지를 열 수 없습니다:`n" GtcState.YPath)
        }
        DrawVisibleAligned(graphics, visibleSource, 0, 0, mainWidth, mainHeight)
        Gdip_DisposeImage(visibleSource)
    } else {
        Gdip_DeleteGraphics(graphics)
        Gdip_DisposeImage(canvas)
        throw Error("알 수 없는 이미지 출력 종류: " imageKind)
    }

    shadowPen := Gdip_CreatePen(0xE0000000, 3)
    markerPen := Gdip_CreatePen(0xFFFFFFFF, 1)
    labelBrush := Gdip_BrushCreateSolid(0xD0000000)

    for marker in MarkerList {
        x := Round((marker.X - GtcState.ThermalCropX) * (mainWidth - 1)
            / (GtcState.ThermalCropWidth - 1))
        y := Round((marker.Y - GtcState.ThermalCropY) * (mainHeight - 1)
            / (GtcState.ThermalCropHeight - 1))
        Gdip_DrawLine(graphics, shadowPen, x - 10, y, x + 10, y)
        Gdip_DrawLine(graphics, shadowPen, x, y - 10, x, y + 10)
        Gdip_DrawLine(graphics, markerPen, x - 10, y, x + 10, y)
        Gdip_DrawLine(graphics, markerPen, x, y - 10, x, y + 10)

        label := FormatGtcTemperature(marker.Temp) "°C"
        measurement := Gdip_TextToGraphics(graphics, label,
            "x0 y0 s12 Bold cFFFFFFFF", "Arial", 140, 36, 1)
        measured := StrSplit(measurement, "|")
        labelWidth := Ceil(measured[3]) + 6
        labelHeight := Ceil(measured[4]) + 2
        labelX := Max(0, Min(mainWidth - labelWidth, x + 5))
        labelY := Max(0, Min(mainHeight - labelHeight, y + 3))
        Gdip_FillRectangle(graphics, labelBrush, labelX, labelY, labelWidth, labelHeight)
        Gdip_TextToGraphics(graphics, label,
            "x" (labelX + 3) " y" (labelY + 1) " s12 Bold cFFFFFFFF",
            "Arial", labelWidth - 4, labelHeight - 1)
    }

    if includeLegend
        DrawSpectrumLegend(graphics, canvasWidth, mainHeight)

    Gdip_DeletePen(shadowPen)
    Gdip_DeletePen(markerPen)
    Gdip_DeleteBrush(labelBrush)
    Gdip_DeleteGraphics(graphics)
    return canvas
}

DrawVisibleAligned(graphics, bitmap, destX, destY, destWidth, destHeight) {
    global GtcState

    drawWidth := destWidth * GtcState.VisibleScale
    drawHeight := destHeight * GtcState.VisibleScale
    shiftX := GtcState.VisibleShiftX * destWidth / GtcState.Width
    shiftY := GtcState.VisibleShiftY * destHeight / GtcState.Height
    drawX := destX + (destWidth - drawWidth) / 2 + shiftX
    drawY := destY + (destHeight - drawHeight) / 2 + shiftY
    Gdip_DrawImage(graphics, bitmap, drawX, drawY, drawWidth, drawHeight)
}

CreateAlignedVisibleBitmap() {
    global GtcState

    visibleSource := Gdip_CreateBitmapFromFile(GtcState.YPath)
    if !visibleSource
        throw Error("실화상 이미지를 열 수 없습니다:`n" GtcState.YPath)

    alignedBitmap := Gdip_CreateBitmap(GtcState.Width, GtcState.Height)
    alignedGraphics := Gdip_GraphicsFromImage(alignedBitmap)
    Gdip_GraphicsClear(alignedGraphics, 0xFF000000)
    Gdip_SetInterpolationMode(alignedGraphics, 7)
    DrawVisibleAligned(alignedGraphics, visibleSource, 0, 0, GtcState.Width, GtcState.Height)
    Gdip_DisposeImage(visibleSource)
    Gdip_DeleteGraphics(alignedGraphics)
    return alignedBitmap
}

CreateBgraBitmap(pixelBuffer, width, height) {
    status := DllCall("gdiplus\GdipCreateBitmapFromScan0",
        "Int", width,
        "Int", height,
        "Int", width * 4,
        "Int", 0x26200A,
        "Ptr", pixelBuffer.Ptr,
        "Ptr*", &bitmap := 0)
    return status = 0 ? bitmap : 0
}

DrawSpectrumLegend(graphics, canvasWidth, canvasHeight) {
    global GtcState

    barX := 490
    barY := 22
    barWidth := 18
    barHeight := canvasHeight - 44
    gradientPixels := Buffer(barWidth * barHeight * 4, 0)

    Loop barHeight {
        y := A_Index - 1
        paletteIndex := Round((barHeight - 1 - y) * 1023 / (barHeight - 1))
        sourceOffset := paletteIndex * 4
        blue := NumGet(GtcState.SpectrumPixels, sourceOffset, "UChar")
        green := NumGet(GtcState.SpectrumPixels, sourceOffset + 1, "UChar")
        red := NumGet(GtcState.SpectrumPixels, sourceOffset + 2, "UChar")
        Loop barWidth {
            targetOffset := (y * barWidth + A_Index - 1) * 4
            NumPut("UChar", blue, gradientPixels, targetOffset)
            NumPut("UChar", green, gradientPixels, targetOffset + 1)
            NumPut("UChar", red, gradientPixels, targetOffset + 2)
            NumPut("UChar", 255, gradientPixels, targetOffset + 3)
        }
    }

    gradientBitmap := CreateBgraBitmap(gradientPixels, barWidth, barHeight)
    Gdip_DrawImage(graphics, gradientBitmap, barX, barY, barWidth, barHeight)
    Gdip_DisposeImage(gradientBitmap)

    borderPen := Gdip_CreatePen(0xFF707070, 1)
    Gdip_DrawRectangle(graphics, borderPen, barX, barY, barWidth, barHeight)
    Gdip_DeletePen(borderPen)

    maxLabel := FormatGtcTemperature(GtcState.MaxTemp) "°C"
    minLabel := FormatGtcTemperature(GtcState.MinTemp) "°C"
    Gdip_TextToGraphics(graphics, maxLabel, "x482 y0 s11 Bold cFF000000", "Arial", canvasWidth - 482, 22)
    Gdip_TextToGraphics(graphics, minLabel, "x482 y" (canvasHeight - 22) " s11 Bold cFF000000", "Arial", canvasWidth - 482, 22)
}

SaveMarkedImage(*) {
    global GtcState, MarkerList, StatusText
    if (MarkerList.Length = 0) {
        MsgBox "먼저 열화상을 클릭해 온도마커를 추가하세요.", "GTC 온도마커", "Iconi"
        return
    }

    SplitPath GtcState.YPath, &visibleFileName, &directory
    SplitPath GtcState.XPath, &thermalFileName
    outputDir := directory "\output"
    DirCreate outputDir
    thermalOutputPath := outputDir "\" thermalFileName
    visibleOutputPath := outputDir "\" visibleFileName

    if (FileExist(thermalOutputPath) || FileExist(visibleOutputPath)) {
        overwrite := MsgBox(
            "출력 파일이 이미 존재합니다. 덮어쓰시겠습니까?`n`n" thermalOutputPath "`n" visibleOutputPath,
            "GTC 온도마커",
            "YN Icon!"
        )
        if (overwrite != "Yes")
            return
    }

    thermalBitmap := BuildMarkedBitmap("thermal", true)
    thermalResult := Gdip_SaveBitmapToFile(thermalBitmap, thermalOutputPath, 95)
    Gdip_DisposeImage(thermalBitmap)

    visibleBitmap := BuildMarkedBitmap("visible", true)
    visibleResult := Gdip_SaveBitmapToFile(visibleBitmap, visibleOutputPath, 95)
    Gdip_DisposeImage(visibleBitmap)

    if (thermalResult != 0 || visibleResult != 0) {
        MsgBox "이미지 저장에 실패했습니다.`n열화상 오류: " thermalResult "`n실화상 오류: " visibleResult,
            "GTC 온도마커", "Iconx"
        return
    }

    StatusText.Text := "열화상/실화상 저장 완료"
    savedMessage := "온도마커 이미지 두 장을 저장했습니다.`n`n열화상:`n" thermalOutputPath
    savedMessage .= "`n`n실화상:`n" visibleOutputPath
    MsgBox savedMessage, "GTC 온도마커", "Iconi"
}

CleanupPrototype(*) {
    global GtcState, ThermalPicture, GdipToken
    try {
        if IsObject(ThermalPicture)
            SetImage(ThermalPicture.Hwnd, 0)
    }
    try {
        if IsObject(GtcState) && GtcState.DllHandle
            DllCall("kernel32\FreeLibrary", "Ptr", GtcState.DllHandle)
    }
    if GdipToken
        Gdip_Shutdown(GdipToken)
}
