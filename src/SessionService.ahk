#Requires AutoHotkey v2.0

class SessionService {
    static Version := 1

    static RootDir() {
        return A_ScriptDir "\temp-work"
    }

    static SessionPath() {
        return this.RootDir() "\session.json"
    }

    static HasRecoverableSession() {
        return FileExist(this.SessionPath()) != ""
    }

    static HasTemporaryFiles() {
        root := this.RootDir()
        if !InStr(FileExist(root), "D")
            return false

        Loop Files root "\*", "FD"
            return true
        return false
    }

    static Create(template, photoResult, imageDir, enabledItemIds, assignments) {
        this.Clear()

        root := this.RootDir()
        originalDir := root "\original"
        processedDir := root "\processed"
        previewDir := root "\preview"
        DirCreate(originalDir)
        DirCreate(processedDir)
        DirCreate(previewDir)

        enabledSet := Map()
        for itemId in enabledItemIds
            enabledSet[itemId] := true

        photoById := Map()
        for photo in photoResult["photos"]
            photoById[photo["id"]] := photo

        sessionItems := []
        for templateItem in template["items"] {
            itemId := templateItem["id"]
            if !enabledSet.Has(itemId)
                continue
            if !assignments.Has(itemId)
                throw Error("사진이 배정되지 않은 점검항목이 있습니다: " templateItem["name"])

            photoId := assignments[itemId]
            if !photoById.Has(photoId)
                throw Error("배정된 사진을 찾을 수 없습니다: " photoId)

            photo := photoById[photoId]
            sourceX := imageDir "\" photo["xFileName"]
            sourceY := imageDir "\" photo["yFileName"]
            if !FileExist(sourceX) || !FileExist(sourceY)
                throw Error("원본 X/Y 사진을 찾을 수 없습니다: " photo["baseName"])

            copiedX := originalDir "\" photo["xFileName"]
            copiedY := originalDir "\" photo["yFileName"]
            FileCopy(sourceX, copiedX, true)
            FileCopy(sourceY, copiedY, true)

            sessionItems.Push(Map(
                "id", itemId,
                "name", templateItem["name"],
                "group", templateItem.Has("group") ? templateItem["group"] : "",
                "label", templateItem.Has("label") ? templateItem["label"] : templateItem["name"],
                "tableOrder", templateItem["tableOrder"],
                "tableIndex", templateItem["tableIndex"],
                "sectionPath", templateItem["sectionPath"],
                "row", templateItem["row"],
                "visibleCell", templateItem["visibleCell"],
                "thermalCell", templateItem["thermalCell"],
                "photoId", photoId,
                "baseName", photo["baseName"],
                "xFileName", photo["xFileName"],
                "yFileName", photo["yFileName"],
                "originalX", copiedX,
                "originalY", copiedY,
                "processedX", processedDir "\" photo["xFileName"],
                "processedY", processedDir "\" photo["yFileName"],
                "markers", [],
                "markerComplete", false
            ))
        }

        if !sessionItems.Length
            throw Error("작업할 점검항목이 없습니다.")

        session := Map(
            "version", this.Version,
            "status", "marker",
            "createdAt", FormatTime(, "yyyy-MM-dd HH:mm:ss"),
            "updatedAt", FormatTime(, "yyyy-MM-dd HH:mm:ss"),
            "templatePath", template["filePath"],
            "templateFileName", template["fileName"],
            "currentItemIndex", 1,
            "items", sessionItems
        )
        this.Save(session)
        return session
    }

    static Load() {
        path := this.SessionPath()
        if !FileExist(path)
            throw Error("이어 할 임시 작업 정보를 찾을 수 없습니다.")

        session := JSON.parse(FileRead(path, "UTF-8"))
        if !session.Has("version") || session["version"] != this.Version
            throw Error("현재 프로그램에서 읽을 수 없는 임시 작업 형식입니다.")
        if !session.Has("items") || !session["items"].Length
            throw Error("임시 작업에 점검항목 정보가 없습니다.")
        return session
    }

    static Save(session) {
        root := this.RootDir()
        DirCreate(root)
        session["updatedAt"] := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        path := this.SessionPath()
        tempPath := path ".tmp"
        if FileExist(tempPath)
            FileDelete(tempPath)
        FileAppend(JSON.stringify(session, 10), tempPath, "UTF-8")
        FileMove(tempPath, path, true)
    }

    static Clear() {
        root := this.RootDir()
        if !InStr(FileExist(root), "D")
            return

        normalizedRoot := StrLower(StrReplace(root, "/", "\"))
        normalizedExpected := StrLower(StrReplace(A_ScriptDir "\temp-work", "/", "\"))
        if (normalizedRoot != normalizedExpected)
            throw Error("임시 작업 폴더 경로가 올바르지 않아 정리하지 않았습니다.")
        DirDelete(root, true)
    }
}
