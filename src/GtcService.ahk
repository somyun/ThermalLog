#Requires AutoHotkey v2.0

class GtcService {
    static GdipToken := 0

    static EnsureReady() {
        if (A_PtrSize != 4)
            throw Error("Bosch GTC 온도 계산 기능은 32비트 AutoHotkey에서 실행해야 합니다.")
        if !this.GdipToken {
            this.GdipToken := Gdip_Startup()
            if !this.GdipToken
                throw Error("GDI+ 초기화에 실패했습니다.")
        }
    }

    static Shutdown() {
        if this.GdipToken {
            Gdip_Shutdown(this.GdipToken)
            this.GdipToken := 0
        }
    }

    static Load(yPath) {
        this.EnsureReady()
        file := FileOpen(yPath, "r")
        if !IsObject(file)
            throw Error("파일을 열 수 없습니다:`n" yPath)

        jpeg := Buffer(file.Length, 0)
        bytesRead := file.RawRead(jpeg)
        file.Close()
        if (bytesRead != jpeg.Size)
            throw Error("JPEG 파일을 끝까지 읽지 못했습니다.")

        section := this.FindGtcApp15(jpeg)
        model := this.ReadAsciiZ(jpeg, section.ModelOffset, 19)
        if !InStr(model, "GTC_400")
            throw Error("현재는 GTC 400 계열만 지원합니다.`n감지된 모델: " model)

        rawWidth := 160
        rawHeight := 120
        rawCount := rawWidth * rawHeight
        rawOffset := section.ModelOffset + 24
        metaOffset := rawOffset + rawCount * 2
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

        appDir := A_ScriptDir "\..\Application"
        dllPath := appDir "\Bosch.GTC.CppWrapper.dll"
        if !FileExist(dllPath)
            throw Error("GTC 계산 DLL이 없습니다:`n" dllPath)

        DllCall("kernel32\SetDllDirectoryW", "Str", appDir, "Int")
        dllHandle := DllCall("kernel32\LoadLibraryW", "Str", dllPath, "Ptr")
        if !dllHandle
            throw Error("Bosch.GTC.CppWrapper.dll 로드 실패.`nWindows 오류: " A_LastError)

        try {
            pInit := this.GetDllProc(dllHandle, "OpenCVInitFn")
            pGetScale := this.GetDllProc(dllHandle, "GetTemperatureScale")
            pColorize := this.GetDllProc(dllHandle, "TemperatureScaleChange")
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
            minMax := Buffer(16, 0)
            DllCall(pGetScale, "Ptr", minMax.Ptr, "Ptr", temperatures.Ptr, "CDecl")

            calculatedMin := NumGet(minMax, 0, "Double")
            calculatedMax := NumGet(minMax, 8, "Double")
            if (calculatedMin > -273)
                minTemp := calculatedMin
            if (calculatedMax > -273)
                maxTemp := calculatedMax

            thermalCrop := this.FindValidTemperatureBounds(temperatures, width, height)
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

            thermalOpaquePixels := Buffer(width * height * 4, 0)
            DllCall("ntdll\RtlMoveMemory", "Ptr", thermalOpaquePixels.Ptr,
                "Ptr", thermalPixels.Ptr, "UPtr", thermalPixels.Size)
            Loop width * height
                NumPut("UChar", 255, thermalOpaquePixels, (A_Index - 1) * 4 + 3)

            xPath := this.PairedThermalPath(yPath)
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

    static Close(state) {
        if IsObject(state) && state.DllHandle
            DllCall("kernel32\FreeLibrary", "Ptr", state.DllHandle)
    }

    static AddMarker(state, markers, displayX, displayY) {
        displayX := Max(0, Min(state.Width - 1, Round(displayX)))
        displayY := Max(0, Min(state.Height - 1, Round(displayY)))
        x := state.ThermalCropX + Round(displayX * (state.ThermalCropWidth - 1) / (state.Width - 1))
        y := state.ThermalCropY + Round(displayY * (state.ThermalCropHeight - 1) / (state.Height - 1))
        temperature := this.TemperatureAt(state, x, y)
        if (temperature <= -273)
            throw Error("유효 온도 영역 밖입니다. 다른 지점을 선택해 주세요.")

        marker := Map(
            "x", x,
            "y", y,
            "temperature", temperature,
            "displayTemperature", this.FormatTemperature(temperature)
        )
        markers.Push(marker)
        return marker
    }

    static RenderPreview(state, markers, imageKind, outputPath) {
        bitmap := this.BuildMarkedBitmap(state, markers, imageKind, false)
        try result := Gdip_SaveBitmapToFile(bitmap, outputPath, 95)
        finally Gdip_DisposeImage(bitmap)
        if (result != 0)
            throw Error("마커 미리보기 저장에 실패했습니다. GDI+ 오류: " result)
    }

    static SaveOutputs(state, markers, thermalOutputPath, visibleOutputPath) {
        if !markers.Length
            throw Error("온도마커를 하나 이상 표시해 주세요.")

        thermalBitmap := this.BuildMarkedBitmap(state, markers, "thermal", true)
        try thermalResult := Gdip_SaveBitmapToFile(thermalBitmap, thermalOutputPath, 95)
        finally Gdip_DisposeImage(thermalBitmap)

        visibleBitmap := this.BuildMarkedBitmap(state, markers, "visible", true)
        try visibleResult := Gdip_SaveBitmapToFile(visibleBitmap, visibleOutputPath, 95)
        finally Gdip_DisposeImage(visibleBitmap)

        if (thermalResult != 0 || visibleResult != 0)
            throw Error("마커 이미지 저장에 실패했습니다. 열화상: " thermalResult ", 실화상: " visibleResult)
    }

    static BuildMarkedBitmap(state, markers, imageKind := "thermal", includeLegend := false) {
        mainWidth := state.Width
        mainHeight := includeLegend ? 370 : state.Height
        canvasWidth := includeLegend ? 536 : mainWidth
        canvas := Gdip_CreateBitmap(canvasWidth, mainHeight)
        graphics := Gdip_GraphicsFromImage(canvas)
        Gdip_GraphicsClear(graphics, 0xFFFFFFFF)
        Gdip_SetInterpolationMode(graphics, 7)

        if (imageKind = "thermal") {
            visibleAligned := this.CreateAlignedVisibleBitmap(state)
            Gdip_DrawImage(graphics, visibleAligned, 0, 0, mainWidth, mainHeight,
                state.ThermalCropX, state.ThermalCropY,
                state.ThermalCropWidth, state.ThermalCropHeight)
            Gdip_DisposeImage(visibleAligned)

            thermalSource := this.CreateBgraBitmap(state.ThermalOpaquePixels, state.Width, state.Height)
            if !thermalSource {
                Gdip_DeleteGraphics(graphics)
                Gdip_DisposeImage(canvas)
                throw Error("DLL 열화상 비트맵 생성에 실패했습니다.")
            }
            Gdip_DrawImage(graphics, thermalSource, 0, 0, mainWidth, mainHeight,
                state.ThermalCropX, state.ThermalCropY,
                state.ThermalCropWidth, state.ThermalCropHeight, 0.70)
            Gdip_DisposeImage(thermalSource)
        } else if (imageKind = "visible") {
            visibleSource := Gdip_CreateBitmapFromFile(state.YPath)
            if !visibleSource {
                Gdip_DeleteGraphics(graphics)
                Gdip_DisposeImage(canvas)
                throw Error("실화상 이미지를 열 수 없습니다:`n" state.YPath)
            }
            this.DrawVisibleAligned(state, graphics, visibleSource, 0, 0, mainWidth, mainHeight)
            Gdip_DisposeImage(visibleSource)
        } else {
            Gdip_DeleteGraphics(graphics)
            Gdip_DisposeImage(canvas)
            throw Error("알 수 없는 이미지 출력 종류: " imageKind)
        }

        shadowPen := Gdip_CreatePen(0xE0000000, 3)
        markerPen := Gdip_CreatePen(0xFFFFFFFF, 1)
        labelBrush := Gdip_BrushCreateSolid(0xD0000000)
        for marker in markers {
            markerX := marker["x"]
            markerY := marker["y"]
            markerTemp := marker["temperature"]
            x := Round((markerX - state.ThermalCropX) * (mainWidth - 1) / (state.ThermalCropWidth - 1))
            y := Round((markerY - state.ThermalCropY) * (mainHeight - 1) / (state.ThermalCropHeight - 1))
            Gdip_DrawLine(graphics, shadowPen, x - 10, y, x + 10, y)
            Gdip_DrawLine(graphics, shadowPen, x, y - 10, x, y + 10)
            Gdip_DrawLine(graphics, markerPen, x - 10, y, x + 10, y)
            Gdip_DrawLine(graphics, markerPen, x, y - 10, x, y + 10)

            label := this.FormatTemperature(markerTemp) "°C"
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
            this.DrawSpectrumLegend(state, graphics, canvasWidth, mainHeight)

        Gdip_DeletePen(shadowPen)
        Gdip_DeletePen(markerPen)
        Gdip_DeleteBrush(labelBrush)
        Gdip_DeleteGraphics(graphics)
        return canvas
    }

    static DrawVisibleAligned(state, graphics, bitmap, destX, destY, destWidth, destHeight) {
        drawWidth := destWidth * state.VisibleScale
        drawHeight := destHeight * state.VisibleScale
        shiftX := state.VisibleShiftX * destWidth / state.Width
        shiftY := state.VisibleShiftY * destHeight / state.Height
        drawX := destX + (destWidth - drawWidth) / 2 + shiftX
        drawY := destY + (destHeight - drawHeight) / 2 + shiftY
        Gdip_DrawImage(graphics, bitmap, drawX, drawY, drawWidth, drawHeight)
    }

    static CreateAlignedVisibleBitmap(state) {
        visibleSource := Gdip_CreateBitmapFromFile(state.YPath)
        if !visibleSource
            throw Error("실화상 이미지를 열 수 없습니다:`n" state.YPath)
        alignedBitmap := Gdip_CreateBitmap(state.Width, state.Height)
        alignedGraphics := Gdip_GraphicsFromImage(alignedBitmap)
        Gdip_GraphicsClear(alignedGraphics, 0xFF000000)
        Gdip_SetInterpolationMode(alignedGraphics, 7)
        this.DrawVisibleAligned(state, alignedGraphics, visibleSource, 0, 0, state.Width, state.Height)
        Gdip_DisposeImage(visibleSource)
        Gdip_DeleteGraphics(alignedGraphics)
        return alignedBitmap
    }

    static CreateBgraBitmap(pixelBuffer, width, height) {
        status := DllCall("gdiplus\GdipCreateBitmapFromScan0",
            "Int", width, "Int", height, "Int", width * 4,
            "Int", 0x26200A, "Ptr", pixelBuffer.Ptr, "Ptr*", &bitmap := 0)
        return status = 0 ? bitmap : 0
    }

    static DrawSpectrumLegend(state, graphics, canvasWidth, canvasHeight) {
        barX := 490
        barY := 22
        barWidth := 18
        barHeight := canvasHeight - 44
        gradientPixels := Buffer(barWidth * barHeight * 4, 0)
        Loop barHeight {
            y := A_Index - 1
            paletteIndex := Round((barHeight - 1 - y) * 1023 / (barHeight - 1))
            sourceOffset := paletteIndex * 4
            blue := NumGet(state.SpectrumPixels, sourceOffset, "UChar")
            green := NumGet(state.SpectrumPixels, sourceOffset + 1, "UChar")
            red := NumGet(state.SpectrumPixels, sourceOffset + 2, "UChar")
            Loop barWidth {
                targetOffset := (y * barWidth + A_Index - 1) * 4
                NumPut("UChar", blue, gradientPixels, targetOffset)
                NumPut("UChar", green, gradientPixels, targetOffset + 1)
                NumPut("UChar", red, gradientPixels, targetOffset + 2)
                NumPut("UChar", 255, gradientPixels, targetOffset + 3)
            }
        }

        gradientBitmap := this.CreateBgraBitmap(gradientPixels, barWidth, barHeight)
        Gdip_DrawImage(graphics, gradientBitmap, barX, barY, barWidth, barHeight)
        Gdip_DisposeImage(gradientBitmap)
        borderPen := Gdip_CreatePen(0xFF707070, 1)
        Gdip_DrawRectangle(graphics, borderPen, barX, barY, barWidth, barHeight)
        Gdip_DeletePen(borderPen)
        maxLabel := this.FormatTemperature(state.MaxTemp) "°C"
        minLabel := this.FormatTemperature(state.MinTemp) "°C"
        Gdip_TextToGraphics(graphics, maxLabel, "x482 y0 s11 Bold cFF000000", "Arial", canvasWidth - 482, 22)
        Gdip_TextToGraphics(graphics, minLabel, "x482 y" (canvasHeight - 22) " s11 Bold cFF000000", "Arial", canvasWidth - 482, 22)
    }

    static TemperatureAt(state, x, y) {
        if (x < 0 || y < 0 || x >= state.Width || y >= state.Height)
            throw Error("온도 좌표가 범위를 벗어났습니다.")
        return NumGet(state.Temperatures, (y * state.Width + x) * 8, "Double")
    }

    static FormatTemperature(value) {
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

    static FindValidTemperatureBounds(temperatures, width, height) {
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

    static FindGtcApp15(jpeg) {
        if (jpeg.Size < 4 || NumGet(jpeg, 0, "UChar") != 0xFF || NumGet(jpeg, 1, "UChar") != 0xD8)
            throw Error("유효한 JPEG 파일이 아닙니다.")
        pos := 2
        while (pos + 4 <= jpeg.Size) {
            if (NumGet(jpeg, pos, "UChar") != 0xFF)
                throw Error("JPEG 마커 구조가 올바르지 않습니다. 위치: " pos)
            marker := NumGet(jpeg, pos + 1, "UChar")
            if (marker = 0xD9 || marker = 0xDA)
                break
            segmentLength := (NumGet(jpeg, pos + 2, "UChar") << 8) | NumGet(jpeg, pos + 3, "UChar")
            if (segmentLength < 2 || pos + 2 + segmentLength > jpeg.Size)
                throw Error("손상된 JPEG 세그먼트입니다. 위치: " pos)
            payloadOffset := pos + 4
            payloadLength := segmentLength - 2
            if (marker = 0xEF) {
                modelOffset := this.FindAscii(jpeg, payloadOffset, Min(payloadLength, 64), "GTC_")
                if (modelOffset >= 0)
                    return {ModelOffset: modelOffset, EndOffset: payloadOffset + payloadLength}
            }
            pos += 2 + segmentLength
        }
        throw Error("GTC 방사측정 APP15 데이터가 없습니다.`n원본 Y.JPG인지 확인하세요.")
    }

    static FindAscii(buffer, startOffset, searchLength, needle) {
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

    static ReadAsciiZ(buffer, offset, maxLength) {
        result := ""
        Loop maxLength {
            value := NumGet(buffer, offset + A_Index - 1, "UChar")
            if (value = 0)
                break
            result .= Chr(value)
        }
        return result
    }

    static GetDllProc(dllHandle, procName) {
        address := DllCall("kernel32\GetProcAddress", "Ptr", dllHandle, "AStr", procName, "Ptr")
        if !address
            throw Error("DLL 함수 주소를 찾지 못했습니다: " procName)
        return address
    }

    static PairedThermalPath(yPath) {
        SplitPath yPath, &fileName, &directory, &extension, &nameNoExt
        if !RegExMatch(nameNoExt, "i)Y$")
            throw Error("선택 파일명이 Y로 끝나지 않습니다:`n" fileName)
        thermalName := RegExReplace(nameNoExt, "i)Y$", "X")
        return directory "\" thermalName "." extension
    }
}
