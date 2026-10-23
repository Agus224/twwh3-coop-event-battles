@echo off
rem VERSION.json controla la version del script, DLL y pack.
rem con la DLL adentro. No instala nada en el juego.
pushd "%~dp0"
echo [1/7] Generando el script de la version actual ...
python generate_companion.py || goto failed
echo [2/7] Compilando ceb_native_bridge.dll ...
call build.cmd || goto failed
echo [3/7] Tests del nucleo nativo (motor simulado) ...
call test_core.cmd || goto failed
echo [4/7] Validacion del binario (pefile) ...
python validate_build.py || goto failed
echo [5/7] Tests del acompanante Lua ...
python test_companion.py || goto failed
echo [6/7] Armando el pack con la DLL adentro ...
node build_pack.cjs || goto failed
echo [7/7] Verificando la DLL embebida en el pack ...
python test_embedded_dll.py || goto failed
echo.
echo LISTO. Solo hace falta dist\coop_event_battles.pack (trae la DLL adentro).
echo Copialo a la carpeta data o subilo a la Workshop. Ambos jugadores usan el mismo.
popd
pause
exit /b 0
:failed
echo.
echo FALLO. Mira el mensaje de arriba.
popd
pause
exit /b 1
