@echo off
REM Setup Zebra Project Environment Variables (Windows)
REM Run this once to set permanent environment variables for the Zebra project
REM Right-click and "Run as Administrator"

echo.
echo Setting up Zebra Project Environment Variables...
echo.

REM Set ZEBRA_PROJECT to the project root
setx ZEBRA_PROJECT "C:\Projects\cobra-language"
echo ✅ Set ZEBRA_PROJECT=C:\Projects\cobra-language

REM Set ZEBRA_BOOK to the book directory
setx ZEBRA_BOOK "C:\Projects\cobra-language\zebra-book"
echo ✅ Set ZEBRA_BOOK=C:\Projects\cobra-language\zebra-book

REM Set ZEBRA_DIAGRAMS to the diagrams directory
setx ZEBRA_DIAGRAMS "C:\Projects\cobra-language\zebra-book\diagrams"
echo ✅ Set ZEBRA_DIAGRAMS=C:\Projects\cobra-language\zebra-book\diagrams

echo.
echo ✨ Environment variables configured!
echo.
echo You may need to restart any open terminals for changes to take effect.
echo.
pause
