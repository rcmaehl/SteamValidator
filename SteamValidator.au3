#include <Array.au3>
#include <File.au3>
#include <FileConstants.au3>
#include <MsgBoxConstants.au3>
#include <ScreenCapture.au3>

; This script validates all games in a user's Steam library
; Author: Shawn Maiberger
;         @ionblade (Twitter)
; By running this script, in whole or in part, you accept that the author is not acceptable for any damage to your computer or data caused by the script.



;_____USER-CONFIGURABLE VARIABLES__________________________________________________________________________________________________________________

; Sometimes, an application does not validate when you call the validation function, and instead immediately comes back as valid.
; Specify the *shortest* amount of time a validation can take to be considered valid in seconds.  Any validation that is shorter than this will
; be invalid, and will be retried, up to the $maxValidationAttempts value.
$minimumValidationTime = 1

; Set the maximum number of times that an application will attempt to be validated due to running too short before we move on and log an exception
$maxValidationAttempts = 3

; Set the amount of time in seconds that an app can stay at 0% complete validation before we assume it has hung (Steam bug that often occurs) and retry
$validationTimeout = 30

; Time to wait between scans in seconds.  Note: if this is set too low, every other scan will fail to execute, as Steam will not be ready and will not throw an error.
$timeBetweenScans = 5
;__________________________________________________________________________________________________________________________________________________

; Try to read in the validation blacklist file.  This file should contain one AppID per line.  Any AppIDs in this file, if present, will not be validated.
; This is useful in cases where some games (e.g. Far Cry 3 and the Dawn of War 2 series) will not silently validate.
$validationBlacklist = 0
If Not _FileReadToArray("validationBlacklist.txt", $validationBlacklist, 0) Then
   $validationBlacklist = 0
EndIf

; Try to read Steam directory from registry
$steamRegLocation = RegRead("HKEY_LOCAL_MACHINE\Software\Valve\Steam","InstallPath")
If @error Then
   $steamRegLocation = ""
Else
   $steamRegLocation = $steamRegLocation & "\steamapps"
EndIf

; Prompt user for the Steamapps directory, prepopulating with the location previously found in the registry, if any
$steamappsDirectory = FileSelectFolder("Please select the steamapps directory within your Steam install directory", $steamRegLocation)
If @error Then
   MsgBox($MB_SYSTEMMODAL, "", "No folder was selected.")
   Exit
EndIf

; Prompt user for location to log results
$loggingDirectory = FileSelectFolder("Please select a writable folder into which results will be logged", "")
If @error Then
   MsgBox($MB_SYSTEMMODAL, "", "No folder was selected.")
   Exit
EndIf

; Get a list of all the games installed in the steamapps directory
$acfFiles = _FileListToArray($steamAppsDirectory, "*.acf")
If @error Then
   MsgBox($MB_SYSTEMMODAL, "", "Either an invalid steamapps path was selected or there are no games installed.")
   Exit
EndIf

; For each of the games installed, get the game's name and Steam ID, then call the verify function on that game.  Wait for verification to complete,
; then take a screenshot of the verification window and continue to the next game.
$validationErrors = 0
$validationWarnings = 0
$validationBlacklistSkips = 0
$validationSuccesses = 0
For $currentFile = 1 to $acfFiles[0]
   ; Set tooltip to let user know progress in systemtray
   TraySetToolTip("Validating item " & $currentFile & "/" & $acfFiles[0] & ".  " & $validationErrors & " apps did not process, " & $validationWarnings & " apps validated too quickly, " & $validationBlacklistSkips & " skipped, " & $validationSuccesses & " successful.")

   $fullAcfPath = $steamappsDirectory & "\" & $acfFiles[$currentFile]

   $appID = ""
   $name = ""

   ; Read through the .acf file to get the AppID and name
   FileOpen($fullAcfPath, 0)
   For $currentLine = 1 to _FileCountLines($fullAcfPath)
	  $line = FileReadLine($fullAcfPath, $currentLine)

	  ; Isolate the AppID by trimming everything between the last <tab><tab>" and the final " character
	  If StringInStr($line, "appID") Then
		 $appID = StringTrimRight(StringTrimLeft($line, StringInStr($line, @TAB & @TAB & '"', 0, -1) + 2), 1)
	  EndIf

	  ; Isolate the name by trimming everything between the last <tab><tab>" and the final " character
	  If StringInStr($line, 'name') Then
		 $name = StringTrimRight(StringTrimLeft($line, StringInStr($line, @TAB & @TAB & '"', 0, -1) + 2), 1)
	  EndIf
   Next
   FileClose($fullAcfPath)

      ; If the current game is in the list of games that do not silently validate, skip it and log to the logfile
   $skipValidation = 0
   For $i = 0 To UBound($validationBlacklist) - 1
	  If StringCompare($validationBlacklist[$i], $appID) = 0 Then
		 $skipValidation = 1
		 ExitLoop
	  EndIf
   Next
   If $skipValidation = 1 Then
	  $hFileOpen = FileOpen($loggingDirectory & "\verificationLog.txt", $FO_APPEND)
      If $hFileOpen = -1 Then
         MsgBox($MB_SYSTEMMODAL, "", "Error writing the result to the selected log directory")
         Exit
	  EndIf
      FileWriteLine($hFileOpen, "WARNING: " & $name & " (" & $appID & ") was skipped because it is in the validation blacklist."  & @CRLF)
	  FileClose($hFileOpen)
	  $validationBlacklistSkips += 1
	  ContinueLoop
   EndIf

   ; Validate the game's files and wait for the validation to finish before continuing.  If this takes less than the user-specified minimum valid
   ; scan time, retry until the number of retries has been hit.
   $validationAttempts = 0
   $validationTime = 0
   $validationFailed = 0
   While $validationTime < $minimumValidationTime AND $validationAttempts < $maxValidationAttempts
      $validationAttempts += 1
      $timer = TimerInit()
      ShellExecute("steam://validate/" & $appID)

      ; Check once a second to see if we are making progress by looking at the % in the title bar of the validation window.
      ; If we hit the validation timeout and are still at 0%, abort and retry.
      While (TimerDiff($timer) / 1000 < $validationTimeout)
         If WinExists("Validating Steam files") Then
            $windowTitle = WinGetTitle("Validating Steam files")

            ; Get how many percent we are through validation
            $EndOfPct = StringInStr($windowTitle, "%", 0, -1) - 1
            $StartOfPct = StringInStr($windowTitle, " ", 0, -1, $EndOfPct) + 1
            $percentageComplete = StringMid($windowTitle, $StartOfPct, $EndOfPct - $StartOfPct + 1)

            If $percentageComplete > 0 Then
               ExitLoop
            EndIf
         EndIf
         Sleep(1000)
      Wend

      ; If we are still at 0% when we hit this point, then we timed out, and we need to abort this validation and retry.
      If $percentageComplete = 0 Then
         ; If we're out of tries to validate this file, log that it failed to validate.
         If $validationAttempts >= $maxValidationAttempts Then
            $hFileOpen = FileOpen($loggingDirectory & "\verificationLog.txt", $FO_APPEND)
            If $hFileOpen = -1 Then
               MsgBox($MB_SYSTEMMODAL, "", "Error writing the result to the selected log directory")
               Exit
            EndIf
            FileWriteLine($hFileOpen, "ERROR: " & $name & " (" & $appID & ") failed to progress past 0% on all attempts."  & @CRLF)
			$validationErrors += 1
			$validationFailed = 1
            FileClose($hFileOpen)
         EndIf

         ; Abort the in-progress validation and move to the next iteration of the loop
         $SteamResults = WinGetHandle("Validating Steam files")
         ControlSend($SteamResults, "", "", "!+{F4}",0)
         Sleep($timeBetweenScans * 1000)
         ContinueLoop
      EndIf

      ; Since we've hit this point, we must be past 0%, so we wait on the validation to complete before moving on
      WinWait("Validating Steam files - 100% complete")
      $validationTime = TimerDiff($timer) / 1000

	  ; Sometimes Steam hits 100% validation before it has *actually* finished displaying the progress bar.  Wait a few seconds to ensure we
	  ; are really done before continuing
	  Sleep(3000)

      ; Save a screenshot of the results
      WinActivate("Validating Steam files - 100% complete")
      $SteamResults = WinGetHandle("Validating Steam files - 100% complete")
      _ScreenCapture_CaptureWnd($loggingDirectory & "\" & StringRegExpReplace($name, '[ /:*?"<>|]', '_') & ".jpg", $SteamResults)

      ; Close the validation window
      ControlSend($SteamResults, "", "", "!+{F4}",0)
   WEnd

   ; Log the validation completed
   $hFileOpen = FileOpen($loggingDirectory & "\verificationLog.txt", $FO_APPEND)
   If $hFileOpen = -1 Then
        MsgBox($MB_SYSTEMMODAL, "", "Error writing the result to the selected log directory")
        Exit
   EndIf
   If $validationFailed = 0 Then
	  If $validationTime < $minimumValidationTime Then
			FileWriteLine($hFileOpen, "WARNING: " & $name & " (" & $appID & ") had abnormally quick validation of " & $validationTime & " seconds."  & @CRLF)
			$validationWarnings += 1
	  Else
		 FileWriteLine($hFileOpen, $name & " (" & $appID & ") validated in " & $validationTime & " seconds."  & @CRLF)
		 $validationSuccesses += 1
	  EndIf
   EndIf
FileClose($hFileOpen)

   ; Give Steam client enough time to prepare for the next scan
   Sleep($timeBetweenScans * 1000)
Next
