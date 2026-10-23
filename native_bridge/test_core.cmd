@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
pushd "%~dp0"
if not exist dist mkdir dist
cl /nologo /std:c11 /W4 /WX /Od /Zi /MT /sdl test_bridge_core.c bridge_core.c /Fe:dist\test_bridge_core.exe /link /INCREMENTAL:NO
if errorlevel 1 goto failed
dist\test_bridge_core.exe
set "CEB_TEST_RESULT=%ERRORLEVEL%"
popd
exit /b %CEB_TEST_RESULT%
:failed
popd
exit /b 1
