# Vendored ConPTY sidecar

These files come from the [Microsoft.Windows.Console.ConPTY](
https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY) NuGet
package (version 1.24.260710001), which redistributes the Windows Terminal
ConPTY client (`conpty.dll`) and its out-of-process host (`OpenConsole.exe`)
under the MIT license. Source: https://github.com/microsoft/terminal

Windows Terminal ships the same pair with the terminal itself. ssterm
installs them next to the executable so the Rust PTY core can prefer them
over the inbox kernel32 pseudoconsole:

- `conpty.dll` exposes `ConptyCreatePseudoConsole` and is loaded at runtime
  by `native/pty_core/src/windows.rs`; if it is missing or unloadable the
  core falls back to kernel32 `CreatePseudoConsole`.
- `OpenConsole.exe` is spawned by `conpty.dll` as the headless console host.
  It opens each session with a DA1 terminal-identification query; the core
  answers it (and strips it from the forwarded stream) because an
  unanswered query stalls the session for roughly three seconds.

Only x64 is vendored today. On other architectures `conpty.dll` fails to
load and the kernel32 fallback keeps sessions working, just slower.

Update procedure:

```sh
curl -sL -o conpty.nupkg \
  https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY
unzip -o -q conpty.nupkg -d conpty_pkg
cp conpty_pkg/runtimes/win-x64/native/conpty.dll windows/conpty/x64/
cp conpty_pkg/build/native/runtimes/x64/OpenConsole.exe windows/conpty/x64/
```
