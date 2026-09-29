ExtractFilenameParts(Filename) {
    if RegExMatch(Filename, "^([^\d]*)(\d+)([^\d]*)\.(.+)$", &Match) {
        return { Prefix: Match[1], Number: Match[2], Suffix: Match[3], Extension: Match[4] }
    } else {
        return false
    }
}

hwpOpen(fileName){
	hwp := ComObject("HWPFrame.hwpObject")
	hwp.XhwpWindows.Item(0).Visible := true

	newOne := WinExist("A")

	action := hwp.HAction
	HPsetFile := hwp.HParameterSet.HFileOpenSave

	action.GetDefault("FileOpen", HPsetFile.HSet)
	HPsetFile.OpenFlag := 0
	HPsetFile.FileName := filename ;StrReplace(StrReplace(A_WorkingDir,"\","\\"),"\\\\","\\") "\\" fileName
	HPsetFile.OpenReadOnly := 0
	HPsetFile.Attributes := 0

	action.Execute("FileOpen", HPsetFile.HSet)

	return hwp
}

hwpScanToMove(hwp, str, count := 1){

	hwp.HAction.Run("MoveDocBegin")

	hwp.HAction.GetDefault("RepeatFind", hwp.HParameterSet.HFindReplace.HSet)
	withHwp := hwp.HParameterSet.HFindReplace
		withHwp.ReplaceString := ""
		withHwp.FindString := str
		withHwp.IgnoreReplaceString := 0
		withHwp.IgnoreFindString := 0
		withHwp.Direction := hwp.FindDir("AllDoc")
		withHwp.WholeWordOnly := 0
		withHwp.UseWildCards := 0
		withHwp.SeveralWords := 0
		withHwp.AllWordForms := 0
		withHwp.MatchCase := 0
		withHwp.ReplaceMode := 0
		withHwp.ReplaceStyle := ""
		withHwp.FindStyle := ""
		withHwp.FindRegExp := 0
		withHwp.FindJaso := 0
		withHwp.HanjaFromHangul := 0
		withHwp.IgnoreMessage := 1
		withHwp.FindType := 1

	loop count {
		withHwp.IgnoreMessage := 1
		if hwp.HAction.Execute("RepeatFind", hwp.HParameterSet.HFindReplace.HSet) == 0
			return false
	}

	return true

}

hwpSetFieldXY(hwp, deleteExist := false){

	cnt := -1
	while 1
	{

		if hwpScanToMove(hwp, "실화상", A_Index) == false
			break

		nowPage := hwp.XHwpDocuments.Item(0).XHwpDocumentInfo.CurrentPage

		if A_Index == 1
			startPage := nowPage
		else if startPage == nowPage
			break

		while 1
		{
			Sleep 100
			hwp.HAction.Run("MoveDown")

			try
				notCell := !hwp.SetCurFieldName("now", 1,0,0)
			catch
				notCell := true

			if InStr(hwp.GetFieldText("now"), "-"){
				hwp.SetCurFieldName("",1,0,0)
				continue
			}

			if StrLen(hwp.GetFieldText("now")) > 2 {
				hwp.SetCurFieldName("",1,0,0)
				break
			}
			else if notCell
				break

			hwp.HAction.Run("TableRightCellAppend")
			Sleep 50
			hwp.SetCurFieldName("x",1,0,0)
			Sleep 50

			if deleteExist {
				hwp.HAction.Run("TableCellBlock")
				hwp.HAction.Run("TableDeleteCell")
				hwp.HAction.Run("Cancel")
			}
			hwp.HAction.Run("TableLeftCell")
			Sleep 50
			hwp.SetCurFieldName("y",1,0,0)
			Sleep 50

			if deleteExist {
				hwp.HAction.Run("TableCellBlock")
				hwp.HAction.Run("TableDeleteCell")
				hwp.HAction.Run("Cancel")
			}

		}

	}
	hwp.HAction.Run("Cancel")

	if 본선TR {
		;본선TR 마지막 필드처리
		hwp.HAction.Run("MoveDocBegin")
		hwpScanToMove(hwp, "본선")

		try
			notCell := !hwp.SetCurFieldName("now", 1,0,0)
		catch
			notCell := true

		if !notCell {
			hwp.HAction.Run("Cancel")
			hwp.SetCurFieldName("",1,0,0)

			loop 4
				hwp.HAction.Run("TableRightCellAppend")

			hwp.SetCurFieldName("y본선",1,0,0)
			if deleteExist {
				hwp.HAction.Run("TableCellBlock")
				hwp.HAction.Run("TableDeleteCell")
				hwp.HAction.Run("Cancel")
			}

			hwp.HAction.Run("TableRightCellAppend")
			hwp.SetCurFieldName("x본선",1,0,0)
			if deleteExist {
				hwp.HAction.Run("TableCellBlock")
				hwp.HAction.Run("TableDeleteCell")
				hwp.HAction.Run("Cancel")
			}
		}
	}
}

hwpRowCount(&addCnt){
	pattern := "(y\{\{(\d+)\}\}|x\{\{(\d+)\}\})" ; y{{숫자}} 또는 x{{숫자}} 추출
	; 패턴 찾기
	pos := 1
	cnt := Array()
	while pos := RegExMatch(hwp.getFieldList(2,1), pattern, &match, pos) {
		cnt.Push(match[1 + A_Index])
		pos += match.Pos[0] + match.Len[0] ; 다음 검색 위치로 이동
	}

	addCnt := InStr(hwp.getFieldList(2,1),"본선")? 1 : 0

	if cnt[1] == cnt[2]
		return cnt[2] + addCnt
	else {
		MsgBox "필드 할당 실패"
		ExitApp
	}
}

dirFiles(&picCnt, &pictures1, &pictures2, &dir){
	pattern1 := "i)^[a-zA-Z]+\d+y+\.(jpg|png|bmp|gif|jpeg)$" ; 그림 파일 이름 패턴
	pattern2 := "i)^([a-zA-Z]+\d+x+|\d+)\.(jpg|png|bmp|gif|jpeg)$"
	pictures1 := Array()
	pictures2 := Array()
	firstpicY := "999999.jpg"
	firstpicX := "999999.jpg"

	if selectedFile := FileSelect(3,,"열화상 일지 자동 사진 삽입기", "한글 Documents (*.hwp; *.hwpx)") {

		; 1. selectedFile 경로에서 폴더 경로 추출
		SplitPath selectedFile,, &dir

		loop Files, dir "\*.JPG", "R" {
			; 파일 이름이 패턴에 맞고, 그림 파일인지 확인
			if RegExMatch(A_LoopFileName, pattern1) {
				pictures1.Push(A_LoopFileName)
				if ExtractFilenameParts(firstpicY).Number > ExtractFilenameParts(A_LoopFileName).Number
					firstpicY := A_LoopFileName
			}
			if RegExMatch(A_LoopFileName, pattern2) {
				pictures2.Push(A_LoopFileName)
				if ExtractFilenameParts(firstpicX).Number > ExtractFilenameParts(A_LoopFileName).Number
					firstpicX := A_LoopFileName
			}
		}

		if pictures1.Length == pictures2.Length {
			picCnt := pictures1.Length
			return selectedFile
		}
		else{
			MsgBox "사진매칭 수량 불량"
			ExitApp
		}

	}
	else
		ExitApp
}

insertPic(hwp, fy, fx, cnt, addCnt, dir){

	dir := StrReplace(dir, "\", "\\")

	MsgBox "접근 허용 경고 메시지가 나타날 시 '모두 허용(A)'을 눌러주세요",,"iconi"

	Loop cnt-addCnt {
		hwp.MoveToField("y{{" A_Index-1 "}}", 1, 0, 0)
		hwp.InsertPicture(dir "\\" fy[A_Index], 1, 3, 0, 0, 0, 0, 0)
		hwp.MoveToField("x{{" A_Index-1 "}}", 1, 0, 0)
		hwp.InsertPicture(dir "\\" fx[A_Index], 1, 3, 0, 0, 0, 0, 0)

		total := A_Index
	}

	if addCnt {
		hwp.MoveToField("y본선", 1, 0, 0)
		hwp.InsertPicture(dir "\\" fy, 1, 3, 0, 0, 0, 0, 0)
		hwp.MoveToField("x본선", 1, 0, 0)
		hwp.InsertPicture(dir "\\" fx, 1, 3, 0, 0, 0, 0, 0)

		total++
	}

	return total

}


MsgBox "※사용방법`n1. 일지와 사진이 같은 폴더에 있어야 합니다.`n2. 사진 파일명에 있는 숫자 순서대로 일지에 입력됩니다.`n3. 실화상사진의 이름은 반드시 'RB00000y.확장자' 이어야하고`n   열화상사진의 이름은 'RB00000x.확장자' or '숫자.확장자'`n4. 본선TR은 가장 마지막 순번의 사진이 입력됩니다.`n5. 사진이 들어갈 칸은 크기가 미리 정해져 있어야 합니다.`n`n준비가 되면 확인을 누르고 일지 파일을 선택해 주세요.",,"iconi"

if MsgBox("본선TR이 있는 일지입니까?","본선TR?","icon? YN")=="Yes"
	본선TR := true
else
	본선TR := false

hwp := hwpOpen(dirFiles(&picCnt, &fy, &fx, &dir))
hwpSetFieldXY(hwp,autoDelete := true)

; 사진수량, 양식수량 비교
rowCnt := hwpRowCount(&addCnt)
if rowCnt == picCnt {

	;사진 입력
	MsgBox "총 " insertPic(hwp, fy, fx, rowCnt, addCnt, dir) * 2 "장의 사진 입력을 완료하였습니다.",,"iconi"
}
else {

	if picCnt < rowCnt
		addmsg := " * " rowCnt "개의 항목 중 " picCnt "쌍의 사진만 입력됩니다"
	else
		addmsg := " * " picCnt "쌍의 사진 중 순번이 빠른 " rowCnt "쌍의 사진만 입력됩니다"

	if MsgBox("사진 수 (" picCnt ") 와 양식칸 수 (" rowCnt " ) 불일치. `n그래도 계속진행하시겠습니까?`n`n" addmsg ,,"YN") == "Yes"
		MsgBox "총 " insertPic(hwp, fy, fx, min(rowCnt, picCnt), addCnt, dir) * 2 "장의 사진 입력을 완료하였습니다.",,"iconi"
	else
		MsgBox "일지와 사진을 같은 폴더에 넣고 실행시켜주세요"

}
ExitApp

hwp.HAction.Run("MoveDocBegin")

ESC::
{
	ExitApp
}
