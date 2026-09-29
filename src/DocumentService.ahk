#Requires AutoHotkey v2.0

class DocumentService {
    static SelectTemplate() {
        return FileSelect(
            3,
            ,
            "과거 열화상 일지 선택",
            "한글 HWPX 문서 (*.hwpx)"
        )
    }

    static AnalyzeTemplate(filePath) {
        if (filePath = "")
            throw Error("선택한 파일이 없습니다.")

        SplitPath(filePath, , , &extension)
        if (StrLower(extension) != "hwpx")
            throw Error("현재는 HWPX 문서만 선택할 수 있습니다.")

        projectRoot := A_ScriptDir "\.."
        analyzerPath := projectRoot "\tools\template_analyzer.py"
        if !FileExist(analyzerPath)
            throw Error("양식 분석 도구를 찾을 수 없습니다.")

        pythonPath := this.FindPython()
        if (pythonPath = "")
            throw Error("문서 분석에 필요한 Python 실행 환경을 찾을 수 없습니다.")

        resultPath := A_Temp "\thermal-template-" A_TickCount ".json"
        command := '"' pythonPath '" "' analyzerPath '" "' filePath '" --output "' resultPath '"'

        try {
            exitCode := RunWait(command, projectRoot, "Hide")
            if !FileExist(resultPath)
                throw Error("양식 분석 결과를 만들지 못했습니다.")

            result := JSON.parse(FileRead(resultPath, "UTF-8"))
            if (exitCode != 0 || !result.Has("success") || !result["success"]) {
                message := result.Has("message") ? result["message"] : "양식을 분석하지 못했습니다."
                throw Error(message)
            }

            return result
        } finally {
            if FileExist(resultPath)
                FileDelete(resultPath)
        }
    }

    static FindPython() {
        bundled := A_ScriptDir "\..\runtime\python\python.exe"
        if FileExist(bundled)
            return bundled

        ; Codex 개발 환경에서만 사용하는 임시 폴백이다. 배포본은 위의
        ; runtime/python을 동봉하므로 이 경로에 의존하지 않는다.
        developmentRuntime := EnvGet("USERPROFILE")
            . "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
        if FileExist(developmentRuntime)
            return developmentRuntime

        pyLauncher := A_WinDir "\py.exe"
        if FileExist(pyLauncher)
            return pyLauncher

        localPrograms := EnvGet("LOCALAPPDATA") "\Programs\Python"
        if InStr(FileExist(localPrograms), "D") {
            candidates := []
            Loop Files localPrograms "\Python*\python.exe", "F"
                candidates.Push(A_LoopFileFullPath)
            if candidates.Length
                return candidates[candidates.Length]
        }

        return ""
    }
}

