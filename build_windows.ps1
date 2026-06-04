# Read version from pubspec.yaml (strips the +build suffix)
$version = (Select-String -Path "pubspec.yaml" -Pattern "^version:").Line `
    -replace "^version:\s*", "" `
    -replace "\+.*$", "" `
    -replace "\s", ""

Write-Host "Building SSTerm $version"

flutter build windows --release

iscc /DMyAppVersion=$version installer.iss
