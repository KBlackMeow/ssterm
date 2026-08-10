/// Returns a PowerShell script that reports the working directory with OSC 7.
/// It chains the user's prompt, which has already loaded before this encoded
/// prelude runs.
String buildPowerShellOsc7Prelude() => r'''
$script:SstmPrevPrompt = if (Test-Path Function:\prompt) { $function:prompt } else { $null }
function global:prompt {
  $sstmCwd = $PWD.ProviderPath -replace '\\', '/'
  [Console]::Out.Write([char]27 + ']7;file:///' + $sstmCwd + [char]27 + '\')
  if ($script:SstmPrevPrompt) { & $script:SstmPrevPrompt } else { "PS $($PWD.Path)> " }
}
''';
