#Requires AutoHotkey v2.0

class DeviceService {
    static BoschVidPid := "VID_108C&PID_017E"
    static BoschStorageId := "VEN_BOSCH&PROD_GTC400C"

    static FindCamera() {
        wmi := ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
        disks := wmi.ExecQuery(
            "SELECT Index, DeviceID, Model, PNPDeviceID, InterfaceType "
            . "FROM Win32_DiskDrive WHERE InterfaceType='USB'"
        )

        for disk in disks {
            model := this.SafeText(disk.Model)
            pnpId := this.SafeText(disk.PNPDeviceID)
            upperModel := StrUpper(model)
            upperPnpId := StrUpper(pnpId)

            isBoschGtc400c := InStr(upperModel, "BOSCH GTC400C")
                || InStr(upperPnpId, this.BoschStorageId)

            if !isBoschGtc400c
                continue

            drive := this.FindLogicalDriveForDisk(wmi, disk.Index)
            if (drive = "")
                drive := this.FindDriveByCameraFolder()

            return this.BuildCameraInfo(model, pnpId, drive, "USB 디스크 모델")
        }

        ; A short fallback window can occur while Windows is assigning a drive.
        fallbackDrive := this.FindDriveByCameraFolder()
        if (fallbackDrive != "")
            return this.BuildCameraInfo(
                "BOSCH GTC400C 추정",
                "WMI 장치 ID 확인 전",
                fallbackDrive,
                "IMAGE 폴더와 X/Y 파일 구조"
            )

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

    static BuildCameraInfo(model, pnpId, drive, detection) {
        imageDir := (drive != "") ? drive "\IMAGE" : ""
        counts := this.CountCameraImages(imageDir)

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
            "detection", detection
        )
    }

    static FindLogicalDriveForDisk(wmi, diskIndex) {
        partitions := wmi.ExecQuery(
            "SELECT DeviceID FROM Win32_DiskPartition WHERE DiskIndex=" diskIndex
        )

        for partition in partitions {
            partitionId := StrReplace(this.SafeText(partition.DeviceID), "'", "''")
            query := "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='" partitionId "'} "
                . "WHERE AssocClass=Win32_LogicalDiskToPartition"

            for logicalDisk in wmi.ExecQuery(query) {
                drive := this.SafeText(logicalDisk.DeviceID)
                if (drive != "")
                    return drive
            }
        }

        return ""
    }

    static FindDriveByCameraFolder() {
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

    static CountCameraImages(imageDir) {
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

    static SafeText(value) {
        try
            return value ""
        catch
            return ""
    }
}

