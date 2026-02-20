# Bundling Python with Electron via python-build-standalone

This document captures the architecture, build process, and hard-won lessons
from shipping a self-contained Electron + FastAPI desktop app that requires
**zero system Python** on the user's machine.

## The Problem

Desktop apps that combine Electron (frontend) with Python (backend) face a
distribution challenge: you can't ask end-users to install Python, manage
virtualenvs, or debug PATH issues. The app needs to "just work" on
double-click.

## The Solution: python-build-standalone (PBS)

[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(maintained by Astral, the makers of `uv` and `ruff`) provides pre-built,
fully self-contained Python interpreters for every major platform and
architecture. These are not system Pythons — they're relocatable binaries
with no external dependencies.

### Why PBS over alternatives?

| Approach | Drawback |
|---|---|
| PyInstaller / cx_Freeze | Bundles the Python app as a standalone executable — hard to integrate with Electron's process model |
| Embedded Python (python.org) | Only available for Windows; macOS/Linux require building from source |
| System Python | Requires user to install Python, version conflicts, PATH issues |
| Conda / Miniconda | ~400MB+ overhead, complex installer, overkill for a single app |
| **PBS** | ~50MB compressed, relocatable, all platforms, no dependencies |

## Architecture

```
User double-clicks app
  -> Electron starts (main.js)
    -> Finds a free TCP port
    -> Spawns bundled Python interpreter:
         python-runtime/bin/python3 backend/app/main.py <port>
       with PYTHONPATH set to bundled site-packages
    -> Polls 127.0.0.1:<port> until FastAPI responds (200ms intervals, 15s timeout)
    -> Creates BrowserWindow pointing at http://127.0.0.1:<port>
  -> On quit: kills Python subprocess
```

### Directory layout inside the packaged app

**macOS** (`.app` bundle):
```
My App.app/Contents/
  MacOS/My App              <- Electron main binary
  Frameworks/               <- Electron framework + helpers
  Resources/
    app.asar                <- Electron JS code (main.js, preload.js)
    python-runtime/         <- PBS Python interpreter
      bin/python3
      lib/python3.12/
      lib/libpython3.12.dylib
    python-venv/
      site-packages/        <- FastAPI, uvicorn, etc.
    backend/
      app/main.py           <- FastAPI application
```

**Windows** (NSIS installer):
```
My App/
  My App.exe
  resources/
    app.asar
    python-runtime/
      python.exe
      python312.dll
      Lib/
    python-venv/
      site-packages/
    backend/
      app/main.py
```

**Linux** (AppImage):
```
Similar to macOS but with python-runtime/bin/python3
```

## Build Process

### Step 1: Download PBS

```bash
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${RELEASE}/cpython-${VERSION}+${RELEASE}-${TRIPLE}-install_only_stripped.tar.gz"
curl -L --fail -o /tmp/python.tar.gz "$PBS_URL"
mkdir -p build/bundle/python-runtime
tar -xf /tmp/python.tar.gz -C build/bundle/python-runtime --strip-components=1
```

Key choices:
- **`install_only_stripped`** variant: smallest size, no debug symbols, no test suite
- **Platform triples**: `aarch64-apple-darwin` (macOS ARM), `x86_64-unknown-linux-gnu` (Linux), `x86_64-pc-windows-msvc` (Windows)

### Step 2: Install Python dependencies

```bash
# Resolve dependencies
cd backend
uv pip compile pyproject.toml -o /tmp/requirements.txt

# Install into a flat target directory (no virtualenv needed)
uv pip install \
  --python build/bundle/python-runtime/bin/python3 \
  -r /tmp/requirements.txt \
  --target build/bundle/python-venv/site-packages
```

Using `--target` creates a flat `site-packages` that works with a simple
`PYTHONPATH` — no virtualenv activation scripts, no `pyvenv.cfg`, no
`site.py` hacks.

### Step 3: Prune the bundle

```bash
cd build/bundle

# Remove bytecode caches and test suites
find . -type d -name "__pycache__" -exec rm -rf {} +
find . -type d -name "tests" -exec rm -rf {} +
find . -type f -name "*.pyc" -delete

# Remove large unused stdlib modules
PYLIB="python-runtime/lib/python3.12"
rm -rf "$PYLIB/tkinter" "$PYLIB/turtle"* "$PYLIB/idlelib" "$PYLIB/ensurepip"
rm -rf "$PYLIB/site-packages/pip" "$PYLIB/site-packages/setuptools"
```

Typical bundle sizes after pruning:
- `python-runtime/`: ~45MB
- `python-venv/site-packages/`: ~15MB (FastAPI + uvicorn)
- Total app (with Electron): ~150-200MB

### Step 4: electron-builder packages it

In `package.json`, `extraResources` tells electron-builder to copy the Python
bundle into the app's resources:

```json
{
  "build": {
    "extraResources": [
      { "from": "../build/bundle/python-runtime", "to": "python-runtime" },
      { "from": "../build/bundle/python-venv", "to": "python-venv" },
      { "from": "../backend", "to": "backend", "filter": ["**/*.py"] }
    ]
  }
}
```

### Step 5 (macOS only): Ad-hoc codesign

This is critical — see the section below.

## macOS Code Signing: The "Damaged App" Problem

### The symptom

When a user downloads the `.dmg` from GitHub (or any browser), macOS shows:

> "My App" is damaged and can't be opened. You should eject the disk image.

### Root cause

macOS Gatekeeper checks the **entire** app bundle when the quarantine flag is
present (set automatically by browsers on download). The check requires:

1. Every Mach-O binary in the bundle must be signed
2. The bundle's sealed resources must be valid

PBS ships pre-built binaries (`.so`, `.dylib`, `python3`) that carry their
own ad-hoc signatures. When electron-builder packages these into the app's
`Resources/` directory, the **main bundle's** signature doesn't seal them
properly. The result:

```
$ codesign -dvvv "My App.app"
Sealed Resources=none    # <-- This is the problem

$ codesign --verify --deep --strict "My App.app"
code has no resources but signature indicates they must be present
```

### The "unidentified developer" vs "damaged" distinction

| Error | Cause | User can bypass? |
|---|---|---|
| "cannot be opened because the developer cannot be verified" | App is properly signed but not notarized | System Settings -> Privacy & Security -> Open Anyway |
| **"is damaged and can't be opened"** | Bundle signature is **broken** (unsealed resources) | **No UI bypass** — must use `xattr -cr` |

The "damaged" error is much worse because there's no GUI workaround.

### The fix: ad-hoc codesign in CI

After electron-builder creates the `.app`, sign everything inside-out:

```bash
APP="dist/mac-arm64/My Desktop App.app"

# 1. Shared libraries and Python extensions
find "$APP" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.node" \) \
  -exec codesign --force --sign - {} \;

# 2. Bundled Python interpreter
codesign --force --sign - "$APP/Contents/Resources/python-runtime/bin/python3"

# 3. Electron helper apps
find "$APP/Contents/Frameworks" -depth -name "*.app" \
  -exec codesign --force --sign - {} \;

# 4. All frameworks (Electron, Mantle, ReactiveObjC, Squirrel)
for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign - "$fw"
done

# 5. Main app bundle (must be last)
codesign --force --sign - "$APP"

# Verify
codesign --verify --deep --strict "$APP"
```

After signing:
```
$ codesign -dvvv "My App.app"
Identifier=com.myapp.desktop
Signature=adhoc
Sealed Resources version=2 rules=13 files=1959   # <-- Fixed
```

**Important**: The DMG must be rebuilt after signing, since the original DMG
contains the unsigned app. Use `electron-builder --pd` to repackage:

```bash
rm -f dist/*.dmg dist/*.blockmap
CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder \
  --mac dmg --arm64 \
  --pd "dist/mac-arm64" \
  --publish never
```

### Signing order matters

macOS code signing is hierarchical. You must sign from the inside out:

1. Individual Mach-O files (`.dylib`, `.so`, executables)
2. Helper `.app` bundles (inside `Frameworks/`)
3. `.framework` bundles (Electron Framework, Mantle, ReactiveObjC, Squirrel)
4. Main `.app` bundle

If you sign the main bundle first, then sign something inside it, the outer
signature becomes invalid.

### For production: Developer ID + notarization

Ad-hoc signing eliminates the "damaged" error, but users still see "Apple
could not verify" on macOS Sequoia (15.x+). For a completely seamless
experience:

1. **Enroll** in the Apple Developer Program ($99/year)
2. **Export** a "Developer ID Application" certificate as `.p12`
3. **Store** it as a GitHub Actions secret (`CSC_LINK` = base64-encoded `.p12`,
   `CSC_KEY_PASSWORD` = password)
4. **Add notarization** after building:
   ```bash
   xcrun notarytool submit "My App.dmg" \
     --apple-id "$APPLE_ID" \
     --team-id "$TEAM_ID" \
     --password "$APP_SPECIFIC_PASSWORD" \
     --wait
   xcrun stapler staple "My App.dmg"
   ```

### User workaround (without notarization)

For ad-hoc signed apps, users must remove the quarantine flag after installing:

```bash
xattr -cr "/Applications/My Desktop App.app"
```

## Electron ↔ Python Communication

### Port allocation

The app uses dynamic port allocation to avoid conflicts:

```javascript
function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}
```

The port is passed to the Python backend as a command-line argument:

```javascript
pythonProcess = spawn(pythonPath, [backendPath, String(port)], { env });
```

### Path resolution

The critical difference between development and packaged mode:

```javascript
const resourcesPath = app.isPackaged
  ? process.resourcesPath                        // -> .app/Contents/Resources/
  : path.join(__dirname, "..", "build", "bundle"); // -> project/build/bundle/
```

### PYTHONPATH setup

Instead of activating a virtualenv, we set `PYTHONPATH` to the flat
site-packages directory:

```javascript
env.PYTHONPATH = path.join(bundlePath, "python-venv", "site-packages");
```

This is simpler and more reliable than trying to activate a virtualenv from
Node.js.

### Startup polling

The Electron window waits for the FastAPI server to be ready:

```javascript
function waitForServer(port, timeoutMs = 15000) {
  // Try TCP connect every 200ms, timeout after 15s
}
```

Typical startup time: 1-3 seconds.

## CI/CD with GitHub Actions

### Matrix strategy

```yaml
matrix:
  include:
    - os: ubuntu-latest    # Linux x86_64
      pbs_triple: x86_64-unknown-linux-gnu
    - os: macos-latest     # macOS ARM (Apple Silicon)
      pbs_triple: aarch64-apple-darwin
    - os: windows-latest   # Windows x86_64
      pbs_triple: x86_64-pc-windows-msvc
```

### Key tools

- **uv** for fast Python dependency resolution and installation
- **electron-builder** for packaging into `.dmg`, `.exe`, `.AppImage`, `.deb`
- **codesign** (macOS) for ad-hoc signing the bundle

### Release flow

```
git tag v1.0.0 && git push origin v1.0.0
  -> GitHub Actions builds all 3 platforms in parallel
  -> Ad-hoc codesigns macOS build
  -> Uploads artifacts
  -> Creates GitHub Release with all binaries
```

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| "damaged and can't be opened" | Unsigned Mach-O binaries in bundle break sealed resources | Ad-hoc codesign all binaries inside-out, rebuild DMG |
| "Apple could not verify" | App is not notarized | `xattr -cr` or enroll in Apple Developer Program |
| Backend fails to start | PYTHONPATH not set correctly | Check `process.resourcesPath` resolution in dev vs packaged mode |
| Python "module not found" | Dependencies not in `site-packages` target | Verify `uv pip install --target` output |
| App hangs on startup | Backend takes too long / port conflict | Increase `waitForServer` timeout, check if port is actually free |
| Large bundle size | Unused stdlib modules | Prune tkinter, test suites, pip/setuptools in build script |
| Windows antivirus flags | Unsigned executable | Sign with a code signing certificate, or users add exception |
