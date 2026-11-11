@echo off
title WB - MoySklad (local)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wb-moysklad-local.ps1"
if errorlevel 1 pause
