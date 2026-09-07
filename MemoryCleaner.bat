@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -Command "& '%~dp0MemoryCleaner.ps1'"
