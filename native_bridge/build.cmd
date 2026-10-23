@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
pushd "%~dp0"
if not exist dist mkdir dist
python prepare_version.py
if errorlevel 1 goto failed
rc /nologo /fo dist\ceb_version.res ceb_version.rc
if errorlevel 1 goto failed
rem These internal engine functions are direct-call sites in the original image;
rem do not add CFG instrumentation that would reject them as indirect targets.
cl /nologo /std:c11 /W4 /WX /O2 /MT /LD /guard:cf- /sdl ceb_native_bridge.c bridge_core.c dist\ceb_version.res /Fe:dist\ceb_native_bridge.dll /link /INCREMENTAL:NO /DYNAMICBASE /NXCOMPAT /Brepro
if errorlevel 1 goto failed
python stamp_native_build.py
set "CEB_BUILD_RESULT=%ERRORLEVEL%"
popd
exit /b %CEB_BUILD_RESULT%
:failed
popd
exit /b 1
