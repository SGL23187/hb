@echo off
rem hb -- AI-friendly environment CLI (Windows launcher)
rem
rem The real thing is D:\2Environment\hb\hb (a bash script, tracked in git,
rem with an embedded payload). This file is only a thin shim: it hands the
rem arguments unchanged to the bash that ships with Git.
rem
rem Why not PowerShell instead of bash: hb is bash all the way through
rem (heredocs, base64, tr/grep/sed). Porting it would mean keeping two copies
rem that drift apart.
rem
rem Why an absolute path to bash: PATH in non-interactive sessions is a
rem snapshot taken at login and may not include D:\2Environment\Git\bin;
rem Git, when installed, always lives at that fixed location.
rem
rem Keep this file ASCII-only. cmd.exe decodes batch bytes with the OEM
rem codepage (936 here), so UTF-8 text gets split into stray characters and
rem the rest of such a line is run as a command ("not recognized" noise).
setlocal
set "HB_BASH=D:\2Environment\Git\bin\bash.exe"
if not exist "%HB_BASH%" (
  >&2 echo [hb] bash not found: %HB_BASH%
  >&2 echo [hb] install Git at D:\2Environment\Git first
  exit /b 127
)
"%HB_BASH%" --noprofile --norc "D:/2Environment/hb/hb" %*
exit /b %ERRORLEVEL%
