#Requires AutoHotkey v2.0

; URL 규칙에 따라 쿠키를 저장하고 전송하는 공용 HTTP 세션입니다.
; CookieJar가 쿠키의 유일한 원본이며, Cookie 헤더 문자열은 요청 시점에만 생성합니다.
class HttpSession {
    __New() {
        this.CookieJar := Map()
        this.EmployeeId := ""
        this.Http := ComObject("WinHttp.WinHttpRequest.5.1")
        this.Http.Option[3] := false  ; WinHTTP 자동 쿠키 교환 비활성화
        this.Http.Option[4] := 13056 ; 사내 인증서 체인 오류 허용
        this.UserAgent := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            . "(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"
        this.CookieRevision := 0
    }

    Request(method, url, body := "", headers := 0, maxRedirects := 12, preserveRedirectHeaders := false) {
        if !IsObject(headers)
            headers := Map()

        currentMethod := StrUpper(method)
        currentUrl := url
        currentBody := body
        currentHeaders := headers.Clone()

        Loop maxRedirects + 1 {
            uri := this.ParseUrl(currentUrl)
            if !this.AllowedHost(uri.Host)
                throw Error("허용되지 않은 호스트 요청을 차단했습니다: " uri.Host)

            http := this.Http
            http.Open(currentMethod, currentUrl, false)
            http.Option[6] := false ; 리다이렉트는 단계별로 직접 처리
            http.SetTimeouts(15000, 15000, 30000, 120000)
            http.SetRequestHeader("User-Agent", this.UserAgent)
            http.SetRequestHeader("Accept", "*/*")

            cookieHeader := this.GetCookieHeaderForUrl(currentUrl)
            if (cookieHeader != "")
                http.SetRequestHeader("Cookie", cookieHeader)

            for name, value in currentHeaders {
                if (StrLower(name) = "cookie")
                    continue
                http.SetRequestHeader(name, value)
            }

            if (currentMethod = "GET" || currentMethod = "HEAD")
                http.Send()
            else
                http.Send(currentBody)

            status := http.Status
            responseHeaders := http.GetAllResponseHeaders()
            this.CaptureCookies(uri, responseHeaders)

            response := {
                Status: status,
                Text: http.ResponseText,
                Body: http.ResponseBody,
                Headers: responseHeaders,
                Url: currentUrl
            }

            if !(status = 301 || status = 302 || status = 303 || status = 307 || status = 308) {
                if (status < 200 || status >= 400)
                    throw Error("HTTP 오류 " status ": " uri.Host uri.Path)
                return response
            }

            if (A_Index > maxRedirects)
                throw Error("리다이렉트 횟수 제한을 초과했습니다.")

            try location := http.GetResponseHeader("Location")
            catch
                throw Error("리다이렉트 Location 헤더가 없습니다.")

            currentUrl := this.ResolveUrl(currentUrl, location)
            if (status = 303 || ((status = 301 || status = 302) && currentMethod = "POST")) {
                currentMethod := "GET"
                currentBody := ""
            }
            currentHeaders := preserveRedirectHeaders ? headers.Clone() : Map()
        }

        throw Error("HTTP 요청이 결과 없이 종료되었습니다.")
    }

    CaptureCookies(uri, allHeaders) {
        for line in StrSplit(allHeaders, "`n", "`r") {
            if RegExMatch(line, "i)^Set-Cookie:\s*(.*)$", &match)
                this.StoreCookie(uri, match[1])
        }
    }

    StoreCookie(uri, rawCookie) {
        if !IsObject(uri)
            uri := this.ParseUrl(uri)

        parts := StrSplit(rawCookie, ";")
        first := Trim(parts[1])
        equals := InStr(first, "=")
        if (equals <= 1)
            return false

        name := Trim(SubStr(first, 1, equals - 1))
        value := SubStr(first, equals + 1)
        domain := uri.Host
        hostOnly := true
        path := this.DefaultCookiePath(uri.Path)
        secure := false
        httpOnly := false
        sameSite := ""
        expires := ""
        deleteCookie := false

        Loop parts.Length - 1 {
            attribute := Trim(parts[A_Index + 1])
            pos := InStr(attribute, "=")
            attrName := StrLower(Trim(pos ? SubStr(attribute, 1, pos - 1) : attribute))
            attrValue := pos ? Trim(SubStr(attribute, pos + 1)) : ""

            switch attrName {
                case "domain":
                    domain := StrLower(LTrim(attrValue, "."))
                    hostOnly := false
                case "path":
                    if (SubStr(attrValue, 1, 1) = "/")
                        path := attrValue
                case "secure":
                    secure := true
                case "httponly":
                    httpOnly := true
                case "samesite":
                    sameSite := this.NormalizeSameSite(attrValue)
                case "expires":
                    expires := attrValue
                    if this.IsExpiredHttpDate(attrValue)
                        deleteCookie := true
                case "max-age":
                    if IsNumber(attrValue) && Number(attrValue) <= 0
                        deleteCookie := true
            }
        }

        if !this.AllowedHost(domain) || !this.DomainMatches(uri.Host, domain)
            return false

        key := domain "|" path "|" name
        if deleteCookie {
            if this.CookieJar.Has(key) {
                this.CookieJar.Delete(key)
                this.CookieRevision += 1
            }
            return true
        }

        this.CookieJar[key] := {
            Name: name,
            Value: value,
            Domain: domain,
            Path: path,
            Secure: secure,
            HostOnly: hostOnly,
            HttpOnly: httpOnly,
            SameSite: sameSite,
            Expires: expires
        }
        this.CookieRevision += 1
        return true
    }

    HasCookieForUrl(url, name) {
        uri := this.ParseUrl(url)
        for _, cookie in this.CookieJar {
            if (cookie.Name = name && this.CookieMatchesUri(cookie, uri))
                return true
        }
        return false
    }

    GetCookieHeaderForUrl(url) {
        uri := this.ParseUrl(url)
        eligible := []

        for _, cookie in this.CookieJar {
            if !this.CookieMatchesUri(cookie, uri)
                continue

            insertAt := eligible.Length + 1
            for index, existing in eligible {
                if (StrLen(cookie.Path) > StrLen(existing.Path)) {
                    insertAt := index
                    break
                }
            }
            eligible.InsertAt(insertAt, cookie)
        }

        output := ""
        for cookie in eligible
            output .= (output = "" ? "" : "; ") cookie.Name "=" cookie.Value
        return output
    }

    GetCookiesForCDP() {
        result := []
        for _, cookie in this.CookieJar {
            item := Map(
                "name", cookie.Name,
                "value", cookie.Value,
                "path", cookie.Path,
                ; JSON.ahk는 일반 0/1을 숫자로 직렬화하므로 CDP 전용 Boolean 타입을 사용한다.
                "secure", cookie.Secure ? JSON.true : JSON.false,
                "httpOnly", cookie.HttpOnly ? JSON.true : JSON.false
            )

            if cookie.HostOnly {
                scheme := cookie.Secure ? "https" : "http"
                item["url"] := scheme "://" cookie.Domain cookie.Path
            } else {
                item["domain"] := "." cookie.Domain
            }

            if (cookie.SameSite != "")
                item["sameSite"] := cookie.SameSite
            if (cookie.Expires != ""
                && this.TryHttpDateToUnix(cookie.Expires, &expiresAt)
                && expiresAt > 0)
                item["expires"] := expiresAt
            result.Push(item)
        }
        return result
    }

    ExportCookies() {
        result := []
        for _, cookie in this.CookieJar {
            result.Push(Map(
                "name", cookie.Name,
                "value", cookie.Value,
                "domain", cookie.Domain,
                "path", cookie.Path,
                "secure", cookie.Secure ? JSON.true : JSON.false,
                "hostOnly", cookie.HostOnly ? JSON.true : JSON.false,
                "httpOnly", cookie.HttpOnly ? JSON.true : JSON.false,
                "sameSite", cookie.SameSite,
                "expires", cookie.Expires
            ))
        }
        return result
    }

    ImportCookies(cookies) {
        this.CookieJar := Map()
        for item in cookies {
            if !item.Has("name") || !item.Has("domain")
                continue

            domain := StrLower(LTrim(item["domain"], "."))
            path := item.Has("path") && SubStr(item["path"], 1, 1) = "/" ? item["path"] : "/"
            name := item["name"]
            if !RegExMatch(domain, "i)(^|\.)humetro\.busan\.kr$") || name = ""
                continue

            key := domain "|" path "|" name
            this.CookieJar[key] := {
                Name: name,
                Value: item.Has("value") ? item["value"] : "",
                Domain: domain,
                Path: path,
                Secure: item.Has("secure") ? this.ToBoolean(item["secure"]) : false,
                HostOnly: item.Has("hostOnly") ? this.ToBoolean(item["hostOnly"]) : true,
                HttpOnly: item.Has("httpOnly") ? this.ToBoolean(item["httpOnly"]) : false,
                SameSite: item.Has("sameSite") ? this.NormalizeSameSite(item["sameSite"]) : "",
                Expires: item.Has("expires") ? item["expires"] : ""
            }
        }
        this.CookieRevision += 1
        return this
    }

    CookieMatchesUri(cookie, uri) {
        if (cookie.Expires != "" && this.IsExpiredHttpDate(cookie.Expires))
            return false
        domainOk := cookie.HostOnly
            ? uri.Host = cookie.Domain
            : this.DomainMatches(uri.Host, cookie.Domain)
        return domainOk
            && this.PathMatches(uri.Path, cookie.Path)
            && (!cookie.Secure || uri.Scheme = "https")
    }

    PathMatches(requestPath, cookiePath) {
        if (requestPath = cookiePath)
            return true
        if (SubStr(requestPath, 1, StrLen(cookiePath)) != cookiePath)
            return false
        return SubStr(cookiePath, -1) = "/" || SubStr(requestPath, StrLen(cookiePath) + 1, 1) = "/"
    }

    AllowedHost(host) {
        host := StrLower(host)
        return host = "humetro.busan.kr" || this.DomainMatches(host, "humetro.busan.kr")
    }

    ParseUrl(url) {
        if !RegExMatch(url, "i)^(https?)://([^/:?#]+)(:\d+)?([^?#]*)", &match)
            throw Error("올바르지 않은 URL입니다: " url)
        path := match[4] = "" ? "/" : match[4]
        scheme := StrLower(match[1])
        host := StrLower(match[2])
        authority := host match[3]
        return {Scheme: scheme, Host: host, Authority: authority, Path: path, Origin: scheme "://" authority}
    }

    DefaultCookiePath(requestPath) {
        slash := InStr(requestPath, "/",, -1)
        return slash <= 1 ? "/" : SubStr(requestPath, 1, slash)
    }

    DomainMatches(host, domain) {
        host := StrLower(host)
        domain := StrLower(domain)
        if (host = domain)
            return true
        difference := StrLen(host) - StrLen(domain)
        return difference > 0
            && SubStr(host, difference + 1) = domain
            && SubStr(host, difference, 1) = "."
    }

    ResolveUrl(baseUrl, location) {
        location := Trim(location)
        if RegExMatch(location, "i)^https?://")
            return location

        base := this.ParseUrl(baseUrl)
        if (SubStr(location, 1, 2) = "//")
            return base.Scheme ":" location
        if (SubStr(location, 1, 1) = "/")
            return base.Origin location

        slash := InStr(base.Path, "/",, -1)
        directory := slash ? SubStr(base.Path, 1, slash) : "/"
        return base.Origin directory location
    }

    NormalizeSameSite(value) {
        switch StrLower(Trim(value)) {
            case "strict": return "Strict"
            case "lax": return "Lax"
            case "none": return "None"
            default: return ""
        }
    }

    ToBoolean(value) {
        if (Type(value) = "ComValue")
            return value == JSON.true
        return !!value
    }

    IsExpiredHttpDate(value) {
        return this.TryHttpDateToUnix(value, &expiresAt)
            && expiresAt <= DateDiff(A_NowUTC, "19700101000000", "Seconds")
    }

    TryHttpDateToUnix(value, &seconds) {
        seconds := 0
        if (value = "")
            return false
        systemTime := Buffer(16, 0)
        try {
            if !DllCall("Wininet.dll\InternetTimeToSystemTimeW", "Str", value, "Ptr", systemTime.Ptr, "UInt", 0)
                return false
            stamp := Format("{:04}{:02}{:02}{:02}{:02}{:02}",
                NumGet(systemTime, 0, "UShort"), NumGet(systemTime, 2, "UShort"),
                NumGet(systemTime, 6, "UShort"), NumGet(systemTime, 8, "UShort"),
                NumGet(systemTime, 10, "UShort"), NumGet(systemTime, 12, "UShort"))
            seconds := DateDiff(stamp, "19700101000000", "Seconds")
            return true
        } catch {
            return false
        }
    }
}
