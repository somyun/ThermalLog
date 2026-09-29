msgTimer(msg, title:="", opt:="") {
    MsgBox msg, title, opt
}

ExtractFilenameParts(Filename) {
    if RegExMatch(Filename, "^([^\d]*)(\d+)([^\d]*)\.(.+)$", &Match) {
        return { Prefix: Match[1], Number: Match[2], Suffix: Match[3], Extension: Match[4] }
    } else {
        return false
    }
}

gtcOpen(dir, filename, gtcV){

	if StrSplit(gtcV,".")[1] > 1 {
		MsgBox "GTC Transfer Software 버전 : " gtcV "`n열화상 자동변환기는 1.7.2이하 버전까지만 지원됩니다.`n2.0.0이상 버전은 추후 지원예정",,"icon!"
		ExitApp
	}
	Run A_WorkingDir "\Application\GTC Transfer Software.exe"

	if !WinWait("GTC Transfer Software", ,3) {
		MsgBox "프로그램이 열리지 않습니다"
		ExitApp
	}

	if WinWait("OpeningMessageBox", ,1){
		ControlSend "{tab}{space}{tab}{space}"
	}

	Sleep 100
	send "#{UP}"
	Sleep 250
	send "!s"
	Sleep 100
	Click 275, 105

}

dirFiles(&dir){
	pattern := "i)^[a-zA-Z]+\d+[yY]+\.(jpg)$" ; 실화상 패턴
	pictures := Array()

	SetTimer msgTimer.Bind("열화상 사진들이 들어있는 폴더에서 사진 하나를 선택하세요.`n(열화상 사진과 실화상 사진은 같은 폴더에 있어야 합니다.)", "열화상 사진 자동 변환기", "iconi t10"), -100

	if selectedFile := FileSelect(3,,"열화상 사진 자동 변환기", "JPG 이미지파일 (*.jpg)") {

		; 1. selectedFile 경로에서 폴더 경로 추출
		SplitPath selectedFile,, &dir

		loop Files, dir "\*.JPG", "F" {
			; 파일 이름이 패턴에 맞고, 그림 파일인지 확인
			if RegExMatch(A_LoopFileName, pattern) and FileExist(dir "\" StrReplace(A_LoopFileName, "Y", "X")){
				pictures.Push(A_LoopFileName)
			}
		}
		if pictures {
			MsgBox "총 " pictures.Length "쌍의 열화상 사진을 감지했습니다",,"iconi"
			return pictures
		}
		return false
	}
	else
		ExitApp
}

initPic(filename, dir){

	static popup := true
	Sleep 250
	send "^t"
	if WinWait("OpeningMessageBox", ,1){
		ControlSend "{tab}{space}{tab}{space}"
	}

	if !WinWait("열다", ,3) {
		Sleep 500
		MsgBox "이미지 열기 대화창이 열리지 않습니다"
		ExitApp
	}

	Sleep 100
	send dir "\" filename
	send "{enter}"

	if WinWaitActive("GTC Transfer Software - BoschGTC", ,5){
		if popup and WinWait("OpeningMessageBox", ,2)
			ControlSend "{tab}{space}{tab}{space}"
		Sleep 1500
		Click 175, 205								;열이미지 100%
		Sleep 250
		Click 370, 205								;슬라이드바 커서 위치
		Sleep 100
		send "{end}"								;실제이미지 전환
		Sleep 250
		Click 372, 109								;온점제거
		Sleep 250
		Click 352, 109								;표식준비
		Click 550, 500, 0
		if popup and WinWait("NewFeatureVideoPopup", ,1)
			ControlSend "{tab}{space}{tab}{space}"

		popup := false
	}
	else{
		MsgBox "이미지 불러오기 실패"
		ExitApp
	}
}

savePic(filename, dir){
	send "^x"												;이미지 내보내기
	if !WinWaitActive("다른 이름으로 저장",,3) {
		MsgBox "저장화면 열기 실패"
		ExitApp
	}
	Sleep 250
	send dir "\output\" filename					;Y 실화상 저장
	send "!s"
	Sleep 100
	send "{enter}"
	Sleep 500

	if !WinWaitActive("GTC Transfer Software - BoschGTC", ,1) {
		MsgBox "저장하기 실패"
		ExitApp
	}

	Click 500, 205								;실제이미지 전환
	Sleep 100
	send "{home}"
	Sleep 1000

	A_Clipboard := StrReplace(filename, "Y", "X") ;X 열화상 저장

	while !FileExist(dir "\output\" A_Clipboard){
		send "^x"
		if !WinWait("다른 이름으로 저장",,3) {
			MsgBox "x사진 저장하기 실패"
			ExitApp
		}
		Sleep 250
		send "^v"
		Sleep 100
		send "!s"
		Sleep 250
		send "{enter}"
		Sleep 250
	}
	if !WinWaitActive("GTC Transfer Software - BoschGTC", ,1) {
		MsgBox "저장하기 실패"
		ExitApp
	}

}

try
	gtcV := FileGetVersion(A_WorkingDir "\Application\GTC Transfer Software.exe")
catch {
	MsgBox A_WorkingDir "\Application\GTC Transfer Software.exe 파일이 존재 하지 않습니다.","열화상 자동 변환기","iconx"
	ExitApp
}

MsgBox "※사용 전 준비`n열화상 실화상 사진 세트는 같은 폴더내에 들어 있어야 합니다.`n폴더 내 모든 사진의 변환이 완료되면 매크로가 종료됩니다.`n모든 변환이 완료되기 전이라도 ESC키를 누를 경우 매크로는 종료됩니다 `n`n준비가 되면 확인을 눌러 안내에 따라 진행해 주세요","열화상 자동 변환기","iconi"

pictures := dirFiles(&dir)
gtcOpen(dir,pictures,gtcV)
DirCreate dir "\output"

for picture in pictures {
	initPic(picture, dir)
	if A_Index == 1 {
		MsgBox "온도를 표시할 부분을 클릭하여 표식을 남기세요`n표식을 마친 후 스페이스바를 누르면 해당 사진이 저장된 후 다음 사진이 로드됩니다.", "열화상 사진 자동 변환기", "iconi"

	}
	if A_Index == 2
		MsgBox "이전 사진과 같이 온도 표시 작업을 반복하세요.`n폴더 내 모든 사진의 변환이 완료되면 프로그램이 종료됩니다", "열화상 사진 자동 변환기", "iconi"

	KeyWait "Space", "D"
	KeyWait "Space"
	savePic(picture, dir)
}

MsgBox "변환이 완료되었습니다.",,"iconi"
ESC::
{
	MsgBox "열화상 변환 매크로 종료", "열화상 자동 변환기", "icon!"
	ExitApp
}
