@echo off
chcp 65001 >nul
title Net monitor
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0netmon.ps1"
