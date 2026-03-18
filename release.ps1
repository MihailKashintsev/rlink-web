#!/usr/bin/env pwsh
# release.ps1 — создать релиз одной командой
# Использование: .\release.ps1 1.2.3

param(
    [Parameter(Mandatory=$true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$Tag = "v$Version"

Write-Host "`n MeshChat Release Script" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host " Version : $Tag" -ForegroundColor White

# 1. Проверяем что нет незакоммиченных изменений
$status = git status --porcelain
if ($status) {
    Write-Host "`n[ERROR] Есть незакоммиченные изменения:" -ForegroundColor Red
    Write-Host $status
    exit 1
}

# 2. Обновляем версию в pubspec.yaml
Write-Host "`n[1/4] Обновляем версию в pubspec.yaml..." -ForegroundColor Yellow
$pubspec = Get-Content "pubspec.yaml" -Raw
$currentVersion = ($pubspec | Select-String -Pattern 'version:\s+([\d.]+)\+(\d+)').Matches[0]
if (-not $currentVersion) {
    Write-Host "[ERROR] Не могу найти версию в pubspec.yaml" -ForegroundColor Red
    exit 1
}

$oldVersionStr = $currentVersion.Value
$buildNum = [int]$currentVersion.Groups[2].Value + 1
$newVersionStr = "version: $Version+$buildNum"

$pubspec = $pubspec -replace [regex]::Escape($oldVersionStr), $newVersionStr
Set-Content "pubspec.yaml" $pubspec -NoNewline

Write-Host "  $oldVersionStr  →  $newVersionStr" -ForegroundColor Green

# 3. Коммитим изменения версии
Write-Host "`n[2/4] Коммитим изменения..." -ForegroundColor Yellow
git add pubspec.yaml
git commit -m "chore: bump version to $Tag"

# 4. Создаём тег
Write-Host "`n[3/4] Создаём тег $Tag..." -ForegroundColor Yellow
git tag -a $Tag -m "Release $Tag"

# 5. Пушим
Write-Host "`n[4/4] Пушим в GitHub..." -ForegroundColor Yellow
git push origin main
git push origin $Tag

Write-Host "`n Готово! GitHub Actions собирает релиз." -ForegroundColor Green
Write-Host " Следи за прогрессом: https://github.com/$env:GITHUB_REPO_URL/actions" -ForegroundColor Cyan
Write-Host " Релиз появится здесь: https://github.com/$env:GITHUB_REPO_URL/releases/tag/$Tag`n" -ForegroundColor Cyan
