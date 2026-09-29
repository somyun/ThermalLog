#Requires AutoHotkey v2.0

class ImageService {
    static ScanPairs(imageDir, requestedCount := 0, previewDir := "") {
        if (imageDir = "" || !InStr(FileExist(imageDir), "D"))
            throw Error("카메라의 IMAGE 폴더를 찾을 수 없습니다.")

        pairMap := Map()

        Loop Files imageDir "\*.JPG", "F" {
            if !RegExMatch(A_LoopFileName, "i)^(.*?)(X|Y)\.JPG$", &match)
                continue

            baseName := StrUpper(match[1])
            kind := StrUpper(match[2])

            if !pairMap.Has(baseName) {
                pairMap[baseName] := Map(
                    "baseName", match[1],
                    "xPath", "",
                    "yPath", "",
                    "xFileName", "",
                    "yFileName", "",
                    "xStamp", "",
                    "yStamp", ""
                )
            }

            pair := pairMap[baseName]
            pair[StrLower(kind) "Path"] := A_LoopFileFullPath
            pair[StrLower(kind) "FileName"] := A_LoopFileName
            pair[StrLower(kind) "Stamp"] := FileGetTime(A_LoopFileFullPath, "M")
        }

        completePairs := []
        incompleteCount := 0

        for baseName, pair in pairMap {
            if (pair["xPath"] = "" || pair["yPath"] = "") {
                incompleteCount += 1
                continue
            }

            stamp := pair["xStamp"] != "" ? pair["xStamp"] : pair["yStamp"]
            pair["captureStamp"] := stamp
            pair["captureDate"] := SubStr(stamp, 1, 4) "-" SubStr(stamp, 5, 2) "-" SubStr(stamp, 7, 2)
            pair["captureTime"] := SubStr(stamp, 9, 2) ":" SubStr(stamp, 11, 2) ":" SubStr(stamp, 13, 2)
            this.InsertSorted(completePairs, pair)
        }

        if (previewDir != "")
            DirCreate(previewDir)

        photos := []

        Loop completePairs.Length {
            pair := completePairs[A_Index]
            previewFileName := pair["yFileName"]
            if (previewDir != "") {
                previewPath := previewDir "\" previewFileName
                if !FileExist(previewPath)
                    || FileGetSize(previewPath) != FileGetSize(pair["yPath"])
                    FileCopy(pair["yPath"], previewPath, true)
            }

            photos.Push(Map(
                "id", pair["baseName"],
                "baseName", pair["baseName"],
                "xFileName", pair["xFileName"],
                "yFileName", pair["yFileName"],
                "previewFileName", previewFileName,
                "captureDate", pair["captureDate"],
                "captureTime", pair["captureTime"],
                "captureStamp", pair["captureStamp"]
            ))
        }

        suggestedCount := requestedCount > 0
            ? Min(requestedCount, completePairs.Length)
            : completePairs.Length

        return Map(
            "requestedCount", requestedCount,
            "suggestedCount", suggestedCount,
            "poolCount", photos.Length,
            "totalComplete", completePairs.Length,
            "incompletePairs", incompleteCount,
            "shortage", Max(0, requestedCount - completePairs.Length),
            "photos", photos
        )
    }

    static InsertSorted(sortedPairs, newPair) {
        if !sortedPairs.Length {
            sortedPairs.Push(newPair)
            return
        }

        Loop sortedPairs.Length {
            if this.ComesBefore(newPair, sortedPairs[A_Index]) {
                sortedPairs.InsertAt(A_Index, newPair)
                return
            }
        }

        sortedPairs.Push(newPair)
    }

    static ComesBefore(left, right) {
        leftDate := SubStr(left["captureStamp"], 1, 8)
        rightDate := SubStr(right["captureStamp"], 1, 8)

        if (leftDate != rightDate)
            return leftDate > rightDate

        leftTime := SubStr(left["captureStamp"], 9)
        rightTime := SubStr(right["captureStamp"], 9)
        if (leftTime != rightTime)
            return leftTime < rightTime

        return StrCompare(left["baseName"], right["baseName"], false) < 0
    }
}

