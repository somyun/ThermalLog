#Requires AutoHotkey v2.0
#Include "HttpSession.ahk"

class SessionProtocol {
    static EncodeFrame(kind, value) {
        return kind "|" this.Base64Encode(JSON.stringify(value)) "`n"
    }

    static DecodeFrame(line, expectedKind := "") {
        separator := InStr(line, "|")
        if (separator <= 1)
            throw Error("세션 프레임 형식이 올바르지 않습니다.")
        kind := SubStr(line, 1, separator - 1)
        if (expectedKind != "" && kind != expectedKind)
            throw Error("예상하지 않은 세션 프레임입니다: " kind)
        payload := JSON.parse(this.Base64Decode(SubStr(line, separator + 1)))
        return {Kind: kind, Payload: payload}
    }

    static ExtractFrames(buffer, chunk) {
        frames := []
        buffer .= chunk
        while (newlinePos := InStr(buffer, "`n")) {
            line := RTrim(SubStr(buffer, 1, newlinePos - 1), "`r")
            buffer := SubStr(buffer, newlinePos + 1)
            if (line != "")
                frames.Push(line)
        }
        return {Frames: frames, Buffer: buffer}
    }

    static Base64Encode(text) {
        byteCount := StrPut(text, "UTF-8") - 1
        bytes := Buffer(byteCount)
        if (byteCount > 0)
            StrPut(text, bytes, "UTF-8")
        size := 0
        flags := 0x40000001 ; CRYPT_STRING_BASE64 | NOCRLF
        DllCall("Crypt32.dll\CryptBinaryToString", "Ptr", bytes.Ptr, "UInt", byteCount,
            "UInt", flags, "Ptr", 0, "UIntP", &size)
        output := Buffer(size * 2, 0)
        DllCall("Crypt32.dll\CryptBinaryToString", "Ptr", bytes.Ptr, "UInt", byteCount,
            "UInt", flags, "Ptr", output.Ptr, "UIntP", &size)
        return StrGet(output, "UTF-16")
    }

    static Base64Decode(value) {
        size := 0
        DllCall("Crypt32.dll\CryptStringToBinary", "Str", value, "UInt", 0, "UInt", 0x1,
            "Ptr", 0, "UIntP", &size, "Ptr", 0, "Ptr", 0)
        bytes := Buffer(size)
        if !DllCall("Crypt32.dll\CryptStringToBinary", "Str", value, "UInt", 0, "UInt", 0x1,
            "Ptr", bytes.Ptr, "UIntP", &size, "Ptr", 0, "Ptr", 0)
            throw OSError(A_LastError, "Base64 디코딩 실패")
        return StrGet(bytes, size, "UTF-8")
    }
}

class SessionStore {
    static FilePath := A_ScriptDir "\.session.dat"

    static BuildBundle(session) {
        return Map(
            "version", 2,
            "employeeId", session.EmployeeId,
            "cookies", session.ExportCookies()
        )
    }

    static FromBundle(bundle) {
        if !bundle.Has("version") || bundle["version"] != 2
            throw Error("지원하지 않는 세션 데이터 형식입니다.")
        if !bundle.Has("employeeId") || !bundle.Has("cookies")
            throw Error("세션 데이터의 필수 항목이 없습니다.")
        session := HttpSession()
        session.EmployeeId := String(bundle["employeeId"])
        session.ImportCookies(bundle["cookies"])
        if (session.EmployeeId = "" || session.CookieJar.Count = 0)
            throw Error("복원할 세션 데이터가 비어 있습니다.")
        return session
    }

    static Save(session) {
        if !IsObject(session) || session.EmployeeId = ""
            throw Error("저장할 세션이 없습니다.")

        serialized := JSON.stringify(this.BuildBundle(session))
        encrypted := this.DpapiProtect(serialized)
        serialized := ""
        tempPath := this.FilePath ".tmp"

        try {
            if FileExist(tempPath)
                FileDelete(tempPath)
            file := FileOpen(tempPath, "w")
            if !IsObject(file)
                throw Error("세션 임시 파일을 만들지 못했습니다.")
            file.RawWrite(encrypted, encrypted.Size)
            file.Close()
            FileMove(tempPath, this.FilePath, true)
        } catch as err {
            if FileExist(tempPath)
                try FileDelete(tempPath)
            throw err
        }
    }

    static Load(employeeId := "") {
        if !FileExist(this.FilePath)
            return 0
        encrypted := FileRead(this.FilePath, "RAW")
        serialized := this.DpapiUnprotect(encrypted)
        bundle := JSON.parse(serialized)
        serialized := ""
        session := this.FromBundle(bundle)
        if (employeeId != "" && session.EmployeeId != employeeId)
            return 0
        return session
    }

    static Clear() {
        if FileExist(this.FilePath)
            try FileDelete(this.FilePath)
        if FileExist(this.FilePath ".tmp")
            try FileDelete(this.FilePath ".tmp")
    }

    static DpapiProtect(text) {
        byteCount := StrPut(text, "UTF-8") - 1
        input := Buffer(byteCount + 1, 0)
        StrPut(text, input, "UTF-8")
        return this.DpapiTransform(input, byteCount, true)
    }

    static DpapiUnprotect(encrypted) {
        output := this.DpapiTransform(encrypted, encrypted.Size, false)
        return StrGet(output.Ptr, output.Size, "UTF-8")
    }

    static DpapiTransform(input, inputSize, protect) {
        blobSize := A_PtrSize = 8 ? 16 : 8
        pointerOffset := A_PtrSize = 8 ? 8 : 4
        inputBlob := Buffer(blobSize, 0)
        outputBlob := Buffer(blobSize, 0)
        NumPut("UInt", inputSize, inputBlob, 0)
        NumPut("Ptr", input.Ptr, inputBlob, pointerOffset)

        functionName := protect ? "Crypt32.dll\CryptProtectData" : "Crypt32.dll\CryptUnprotectData"
        succeeded := DllCall(functionName,
            "Ptr", inputBlob.Ptr, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0,
            "UInt", 0x1, "Ptr", outputBlob.Ptr, "Int")
        if !succeeded
            throw OSError(A_LastError, protect ? "세션 암호화 실패" : "세션 복호화 실패")

        outputSize := NumGet(outputBlob, 0, "UInt")
        outputPointer := NumGet(outputBlob, pointerOffset, "Ptr")
        try {
            output := Buffer(outputSize)
            DllCall("Kernel32.dll\RtlMoveMemory", "Ptr", output.Ptr,
                "Ptr", outputPointer, "UPtr", outputSize)
            return output
        } finally {
            DllCall("Kernel32.dll\LocalFree", "Ptr", outputPointer, "Ptr")
        }
    }
}

class XPlatformProtocol {
    static Namespace := "http://www.tobesoft.com/platform/Dataset"

    static BuildSsoLoginXml(employeeId) {
        trans := this.BuildTransInfo("ssoLogin", "ssoLogin.do", "ds_in", "ds_out3", true)
        input := "<Dataset id=" this.Q("ds_in") ">"
            . "<ColumnInfo>"
            . this.BuildColumn("IN_USERID") this.BuildColumn("IN_PASSWORD") this.BuildColumn("IN_CERT_NUMB")
            . "</ColumnInfo><Rows><Row type=" this.Q("insert") ">"
            . "<Col id=" this.Q("IN_USERID") ">" this.XmlEscape(employeeId) "</Col>"
            . "</Row></Rows></Dataset>"
        return this.Root(this.BuildParameters(Map("queryId", "login.userSSOSelect")) trans input)
    }

    static BuildApprovalQueryXml(startDate, endDate) {
        params := Map(
            "queryId", "LA10100.searchExcel",
            "IN_START_DATE", startDate,
            "IN_END_DATE", endDate,
            "IN_LINE_CODE", "",
            "IN_STST_CODE", "",
            "IN_FNST_CODE", "",
            "IN_REQU_BSCD", "",
            "IN_WORK_CODE", "",
            "IN_STUS", ""
        )
        return this.Root(this.BuildParameters(params)
            . this.BuildTransInfo("searchExcel", "selectList.do", "", "", false))
    }

    static EnsureSuccess(xmlText, isSsoInit := false) {
        doc := this.LoadXml(xmlText)
        codeNode := doc.SelectSingleNode("//*[local-name()='Parameter' and @id='ErrorCode']")
        msgNode := doc.SelectSingleNode("//*[local-name()='Parameter' and @id='ErrorMsg']")
        if !codeNode
            throw Error("XPlatform 응답에 ErrorCode가 없습니다.")

        code := Trim(codeNode.Text)
        message := msgNode ? Trim(msgNode.Text) : "알 수 없는 오류"
        if (code = "0")
            return doc
        if (code = "-99999")
            throw Error("SESSION_EXPIRED: MIS 세션이 없거나 만료되었습니다.")
        if isSsoInit && InStr(message, "통합 로그인")
            throw Error("MIS 통합 SSO 초기화에 실패했습니다.")
        throw Error("XPlatform 오류 " code ": " message)
    }

    static LoadXml(text) {
        text := LTrim(text, Chr(0xFEFF))
        doc := ComObject("MSXML2.DOMDocument.6.0")
        doc.Async := false
        doc.ValidateOnParse := false
        if !doc.LoadXML(text)
            throw Error("XML 응답을 해석하지 못했습니다.")
        return doc
    }

    static BuildTransInfo(serviceId, url, inputName, outputName, includeRow) {
        xml := "<Dataset id=" this.Q("__DS_TRANS_INFO__") "><ColumnInfo>"
            . this.BuildColumn("strSvcID") this.BuildColumn("strURL")
            . this.BuildColumn("strInDatasets") this.BuildColumn("strOutDatasets")
            . "</ColumnInfo><Rows>"
        if includeRow {
            xml .= "<Row type=" this.Q("insert") ">"
                . "<Col id=" this.Q("strSvcID") ">" this.XmlEscape(serviceId) "</Col>"
                . "<Col id=" this.Q("strURL") ">" this.XmlEscape(url) "</Col>"
                . "<Col id=" this.Q("strInDatasets") ">" this.XmlEscape(inputName) "</Col>"
                . "<Col id=" this.Q("strOutDatasets") ">" this.XmlEscape(outputName) "</Col>"
                . "</Row>"
        }
        return xml "</Rows></Dataset>"
    }

    static BuildColumn(id) {
        return "<Column id=" this.Q(id) " type=" this.Q("STRING") " size=" this.Q("256") "/>"
    }

    static BuildParameters(values) {
        xml := "<Parameters>"
        for key, value in values
            xml .= "<Parameter id=" this.Q(key) ">" this.XmlEscape(value) "</Parameter>"
        return xml "</Parameters>"
    }

    static Root(innerXml) {
        return "<?xml version=" this.Q("1.0") " encoding=" this.Q("UTF-8") "?>"
            . "<Root xmlns=" this.Q(this.Namespace) " ver=" this.Q("5000") ">"
            . innerXml "</Root>"
    }

    static Q(value) {
        return Chr(34) value Chr(34)
    }

    static XmlEscape(value) {
        value := StrReplace(value, "&", "&amp;")
        value := StrReplace(value, "<", "&lt;")
        value := StrReplace(value, ">", "&gt;")
        value := StrReplace(value, Chr(34), "&quot;")
        return StrReplace(value, "'", "&apos;")
    }
}

class SessionAuthenticator {
    static BasePortal := "https://btcep.humetro.busan.kr"
    static BaseMis := "https://mis.humetro.busan.kr/FS"

    static Acquire(credentials) {
        employeeId := credentials["사번"]

        try {
            restored := SessionStore.Load(employeeId)
            if IsObject(restored) {
                this.ValidateUnifiedSession(restored, employeeId)
                LogDebug("저장된 통합 세션 검증 성공")
                return restored
            }
        } catch as err {
            LogDebug("저장 세션을 사용할 수 없어 새로 로그인합니다: " err.Message)
            SessionStore.Clear()
        }

        session := HttpSession()
        this.LoginPortalAndCentralSso(session, credentials)
        this.PrepareMisSession(session, employeeId)
        this.PrepareEpSession(session, employeeId)
        session.EmployeeId := employeeId
        this.ValidateUnifiedSession(session, employeeId)
        return session
    }

    static LoginPortalAndCentralSso(session, credentials) {
        loginPage := this.BasePortal "/user/login.face?destination=%2Fportal%2F"
        session.StoreCookie(session.ParseUrl(this.BasePortal "/"),
            "EnviewLangKnd=ko; Domain=humetro.busan.kr; Path=/; Secure")
        session.Request("GET", loginPage)

        firstJson := JSON.stringify(Map("userId", credentials["사번"], "pwd", credentials["1차비번"]))
        ajaxHeaders := Map(
            "X-Requested-With", "XMLHttpRequest",
            "Referer", loginPage,
            "Content-Type", "application/json;charset=UTF-8"
        )
        checkUser := session.Request("POST", this.BasePortal "/user/checkUser.face", firstJson, ajaxHeaders)
        if (Trim(checkUser.Text) != "1")
            throw Error("포털 1차 사용자 확인에 실패했습니다.")

        checkLogin := session.Request("POST", this.BasePortal "/user/checkLogin.face", firstJson, ajaxHeaders)
        if !RegExMatch(checkLogin.Text, "i)" Chr(34) "str" Chr(34) "\s*:\s*" Chr(34) "success" Chr(34))
            throw Error("포털 1차 비밀번호 확인에 실패했습니다.")

        secondJson := JSON.stringify(Map("userId", credentials["사번"], "secondpwd", credentials["2차비번"]))
        secondLogin := session.Request("POST", this.BasePortal "/user/secondLoginYn.face", secondJson, ajaxHeaders)
        if (Trim(secondLogin.Text) != "1")
            throw Error("포털 2차 비밀번호 확인에 실패했습니다.")
        session.Request("POST", this.BasePortal "/user/failReset.face", secondJson, ajaxHeaders)

        form := "username=" this.UrlEncode(credentials["사번"])
            . "&userId=" this.UrlEncode(credentials["사번"])
            . "&password=" this.UrlEncode(credentials["1차비번"])
        portalResult := session.Request("POST", this.BasePortal "/user/loginProcess.face?destination=%2Fportal%2F",
            form, Map(
                "Content-Type", "application/x-www-form-urlencoded",
                "Origin", this.BasePortal,
                "Referer", loginPage
            ))
        if !InStr(portalResult.Url, this.BasePortal "/portal/")
            throw Error("포털 최종 로그인 페이지에 도달하지 못했습니다.")

        session.StoreCookie(session.ParseUrl(this.BasePortal "/"),
            "EnviewLangKnd=ko; Domain=humetro.busan.kr; Path=/; Secure")
        if !session.HasCookieForUrl("https://sso.humetro.busan.kr/sso/pmi-sso2.jsp", "JSESSIONID")
            throw Error("중앙 SSO 세션을 받지 못했습니다.")
        LogDebug("포털 및 중앙 SSO 로그인 성공")
    }

    static PrepareMisSession(session, employeeId) {
        this.InitializeNiwMisSsoBridge(session)
        session.Request("GET", this.BaseMis "/index.jsp?gv_selSystGubn=LA")
        if !session.HasCookieForUrl(this.BaseMis "/ssoLogin.do", "JSESSIONID")
            throw Error("MIS 세션을 받지 못했습니다.")
        session.Request("GET", this.BaseMis "/xui/install.jsp?gv_selSystGubn=LA")

        ssoPage := session.Request("GET",
            this.BaseMis "/xui/install/x_installChromeSSO.jsp?gv_selSystGubn=LA&gv_userBrowser=Edg")
        if !RegExMatch(ssoPage.Text, "i)var\s+userId\s*=\s*'([^']*)'", &match)
            throw Error("MIS SSO 응답에서 사용자 식별자를 찾지 못했습니다.")
        if (Trim(match[1]) != Trim(employeeId))
            throw Error("MIS SSO 사용자가 로그인 계정과 일치하지 않습니다.")

        response := session.Request("POST", this.BaseMis "/ssoLogin.do",
            XPlatformProtocol.BuildSsoLoginXml(employeeId),
            Map("Content-Type", "text/xml;charset=UTF-8"))
        XPlatformProtocol.EnsureSuccess(response.Text, true)
        LogDebug("MIS XPlatform 세션 초기화 성공")
    }

    static InitializeNiwMisSsoBridge(session) {
        timestamp := this.EpochMilliseconds()
        bridgeUrl := "https://niw.humetro.busan.kr/sso/index.jsp"
            . "?callType=callMenu&menuType=fwdlogin&bw=edge"
            . "&callback=showJsonMISSSO&_=" timestamp
        headers := Map(
            "Accept", "*/*",
            "Accept-Language", "ko,en;q=0.9,en-US;q=0.8",
            "Referer", this.BasePortal "/",
            "Sec-Fetch-Dest", "script",
            "Sec-Fetch-Mode", "no-cors",
            "Sec-Fetch-Site", "same-site"
        )

        Loop 2 {
            response := session.Request("GET", bridgeUrl, "", headers, 16, true)
            finalUri := session.ParseUrl(response.Url)
            if (finalUri.Host = "niw.humetro.busan.kr"
                && StrLower(finalUri.Path) = "/sso/index.jsp"
                && RegExMatch(response.Text, "i)" Chr(34) "Result" Chr(34)
                    "\s*:\s*" Chr(34) "S" Chr(34)))
                return
            if (A_Index < 2)
                Sleep(500)
        }
        throw Error("NIW MIS SSO 브리지 초기화에 실패했습니다.")
    }

    static PrepareEpSession(session, employeeId) {
        timestamp := this.EpochMilliseconds()
        niwUrl := "https://niw.humetro.busan.kr/sso/index.jsp"
            . "?callType=callMenu&menuType=fwdlogin&bw=chrome&_=" timestamp
        session.Request("GET", niwUrl, "", Map("Referer", this.BasePortal "/"))

        erpepUrl := "https://niw.humetro.busan.kr/erpep.jsp"
        erpep := session.Request("GET", erpepUrl, "", Map(
            "Referer", this.BasePortal "/portal/default/main/erpportal.page"))
        if !RegExMatch(erpep.Text, "let authCd = '([^']+)';", &match)
            throw Error("ERP 인증값을 찾지 못했습니다.")
        kValue := match[1]

        ssoDataUrl := "http://ep.humetro.busan.kr/irj/servlet/prt/portal/prtroot/"
            . "kr.busan.humetro.cbo.ep.ssoLogin.SSOData"
        ssoPayload := JSON.stringify(Map("I_SABUN", kValue, "I_RET", ""))
        dynamicPassword := ""
        Loop 3 {
            response := session.Request("POST", ssoDataUrl, ssoPayload, Map(
                "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8",
                "Origin", "http://ep.humetro.busan.kr",
                "Referer", "http://ep.humetro.busan.kr/irj/portal?K=" kValue
            ))
            parts := StrSplit(response.Text, "@")
            if (parts.Length >= 4) {
                dynamicPassword := Trim(parts[4], "`r`n ")
                break
            }
            if (A_Index < 3)
                Sleep(1000)
        }
        if (dynamicPassword = "")
            throw Error("ERP 동적 인증정보를 받지 못했습니다.")

        epLoginUrl := "http://ep.humetro.busan.kr/irj/portal?K=" kValue
        loginBody := "login_submit=on&login_do_redirect=1&no_cert_storing=on"
            . "&j_user=" this.UrlEncode(employeeId)
            . "&j_password=" this.UrlEncode(dynamicPassword)
            . "&nocomp=&newPw=&pwCheck=&WorkNo=&Name=&phoneNum="
        dynamicPassword := ""
        session.Request("POST", epLoginUrl, loginBody, Map(
            "Content-Type", "application/x-www-form-urlencoded",
            "Origin", "http://ep.humetro.busan.kr",
            "Referer", epLoginUrl
        ))
        if !session.HasCookieForUrl(epLoginUrl, "MYSAPSSO2")
            throw Error("EP MYSAPSSO2를 받지 못했습니다.")

        innerUrl := "http://ep.humetro.busan.kr/irj/servlet/prt/portal/prtroot/"
            . "pcd!3aportal_content!2fhumetro!2fdesktop!2fdesktop.default!2fframeworkPages!2f"
            . "layout.framework!2fcom.sap.portal.innerpage?K=" kValue
            . "&windowId=WID" this.EpochMilliseconds()
        inner := session.Request("GET", innerUrl, "", Map("Referer", epLoginUrl))
        if !RegExMatch(inner.Text, 'var\s+userinfo\s*=\s*"UserMasterEntity:\{(.*?)\}"', &userMatch)
            throw Error("EP 사용자 정보를 찾지 못했습니다.")
        userInfo := userMatch[1]

        portalCookie := this.BuildPortalCookie(userInfo)
        session.StoreCookie(session.ParseUrl("http://ep.humetro.busan.kr/"),
            "SAPPORTALSDB0=" portalCookie "; Domain=humetro.busan.kr; Path=/")

        userValues := this.ExtractEpUserValues(userInfo)
        this.WarmEpSession(session, kValue, userValues)
        LogDebug("EP/ERP 세션 초기화 성공")
    }

    static ValidateUnifiedSession(session, employeeId) {
        if !IsObject(session) || employeeId = ""
            throw Error("통합 세션 검증 정보가 없습니다.")
        if (session.EmployeeId != "" && session.EmployeeId != employeeId)
            throw Error("저장 세션의 사용자가 현재 로그인 계정과 다릅니다.")
        if !session.HasCookieForUrl(this.BasePortal "/portal/", "JSESSIONID")
            throw Error("포털 세션 쿠키가 없습니다.")
        if !session.HasCookieForUrl("https://sso.humetro.busan.kr/sso/pmi-sso2.jsp", "JSESSIONID")
            throw Error("중앙 SSO 세션 쿠키가 없습니다.")
        if !session.HasCookieForUrl(this.BaseMis "/ssoLogin.do", "JSESSIONID")
            throw Error("MIS 세션 쿠키가 없습니다.")
        if !session.HasCookieForUrl("http://ep.humetro.busan.kr/irj/portal", "MYSAPSSO2")
            throw Error("EP 세션 쿠키가 없습니다.")

        portalCheck := session.Request("GET", this.BasePortal "/portal/")
        if InStr(StrLower(portalCheck.Url), "/user/login")
            throw Error("포털 세션이 만료되었습니다.")

        ; /portal/은 열리더라도 업무 포털 세션이 부분 만료되어 근태 AJAX 요청만
        ; '로그 아웃' HTML을 반환할 수 있다. 실제 근태 API까지 JSON 응답인지 확인한다.
        this.ValidateGuntaeSession(session)

        misResponse := session.Request("POST", this.BaseMis "/ssoLogin.do",
            XPlatformProtocol.BuildSsoLoginXml(employeeId),
            Map("Content-Type", "text/xml;charset=UTF-8"))
        XPlatformProtocol.EnsureSuccess(misResponse.Text, true)

        ; K는 로그인 시점의 일회성 값이므로 저장 세션 검증에 재사용하지 않는다.
        ; MYSAPSSO2를 실제 EP 포털에 보내 로그인 화면으로 되돌아가는지 확인한다.
        epCheck := session.Request("GET", "http://ep.humetro.busan.kr/irj/portal")
        epText := StrLower(epCheck.Text)
        if InStr(StrLower(epCheck.Url), "login")
            || InStr(epText, 'name="j_password"')
            || InStr(epText, "name='j_password'")
            throw Error("EP 세션이 만료되었습니다.")
        session.EmployeeId := employeeId
        return true
    }

    static ValidateGuntaeSession(session) {
        url := this.BasePortal "/main/getDeptDetail.face"
        today := FormatTime(A_Now, "yyyy-MM-dd")
        payload := JSON.stringify(Map("codeVal", "0", "dateVal", today))
        response := session.Request("POST", url, payload, Map(
            "Accept", "application/json, text/javascript, */*; q=0.01",
            "Content-Type", "application/json; charset=UTF-8",
            "X-Requested-With", "XMLHttpRequest",
            "Origin", this.BasePortal,
            "Referer", this.BasePortal "/main/Geuntae.face"
        ))

        if RegExMatch(response.Text, "i)<title[^>]*>\s*로그\s*아웃\s*</title>")
            throw Error("근태 포털 세션이 만료되었습니다.")

        try data := JSON.parse(response.Text)
        catch as err
            throw Error("근태 포털 세션이 JSON 응답을 반환하지 않았습니다: " err.Message)
        if !(data is Array)
            throw Error("근태 포털 세션 검증 응답 형식이 올바르지 않습니다.")
        return true
    }

    static BuildPortalCookie(userInfo) {
        cookieData := "urn%253Akr.busan.humetro%253Anavigation%2526title%3DERP%25uD3EC%25uD138%25uC2DC%25uC2A4%25uD15C%3B%20"
            . "urn%253Akr.busan.humetro%253Anavigation%2526pcdid%3DROLES%253A//portal_content/"
            . "humetro/role/home/role.01/workset.home/page.06"
        allowed := ",SABUN,NAME,BUSEO_CODE,BUSEO_NAME,JIKGUB_CODE,JIKGUB_NAME,JIKWI_CODE,JIKWI_NAME,JIKYEL_CODE,JIKYEL_NAME,"
        for pair in StrSplit(userInfo, ",") {
            pos := InStr(pair, "=")
            if (pos <= 1)
                continue
            key := SubStr(pair, 1, pos - 1)
            value := SubStr(pair, pos + 1)
            if InStr(allowed, "," key ",")
                cookieData .= "%3B%20" this.UrlEncode("urn:kr.busan.humetro:userinfo&" key)
                    . "%3D" this.UrlEncode(value)
        }
        return cookieData
    }

    static ExtractEpUserValues(userInfo) {
        result := Map("SABUN", "", "NAME", "", "BUSEO_CODE", "", "BUSEO_NAME", "")
        for key in result {
            if RegExMatch(userInfo, key "=([^,]+)", &match)
                result[key] := match[1]
        }
        return result
    }

    static WarmEpSession(session, kValue, values) {
        ssoPayload := JSON.stringify(Map("I_SABUN", kValue, "I_RET", ""))
        ssoGetUrl := "http://ep.humetro.busan.kr/irj/servlet/prt/portal/prtroot/"
            . "kr.busan.humetro.cbo.ep.ssoLogin.SSOgetSabun"
        referer := "http://ep.humetro.busan.kr/irj/portal?K=" kValue
        session.Request("POST", ssoGetUrl, ssoPayload, Map(
            "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8",
            "Origin", "http://ep.humetro.busan.kr", "Referer", referer))

        warmupPayload := JSON.stringify(Map(
            "AJAX_TYPE", "HEAD",
            "SABUN", values["SABUN"],
            "NAME", values["NAME"],
            "BUSEO_CODE", values["BUSEO_CODE"],
            "BUSEO_NAME", values["BUSEO_NAME"]
        ))
        warmupUrl := "http://ep.humetro.busan.kr/irj/servlet/prt/portal/prtroot/"
            . "kr.busan.humetro.cbo.ep.search_value.SearchValueData"
        session.Request("POST", warmupUrl, warmupPayload, Map(
            "Accept", "*/*",
            "Cache-Control", "no-cache",
            "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With", "XMLHttpRequest",
            "Origin", "http://ep.humetro.busan.kr",
            "Referer", referer
        ))
    }

    static UrlEncode(value) {
        byteCount := StrPut(value, "UTF-8")
        encodedBytes := Buffer(byteCount)
        StrPut(value, encodedBytes, "UTF-8")
        output := ""
        Loop byteCount - 1 {
            byte := NumGet(encodedBytes, A_Index - 1, "UChar")
            if ((byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte = 0x2D || byte = 0x2E || byte = 0x5F || byte = 0x7E)
                output .= Chr(byte)
            else
                output .= "%" Format("{:02X}", byte)
        }
        return output
    }

    static EpochMilliseconds() {
        return DateDiff(A_NowUTC, "19700101000000", "Seconds") * 1000
    }
}
        
