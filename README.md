# Electron + FastAPI Desktop App

Desktop application with an Electron frontend and FastAPI backend, using
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
to ship a fully self-contained Python runtime. No system Python required.

## Architecture

```
User launches app
  → Electron starts
    → Spawns bundled Python interpreter running FastAPI on a random port
      → Electron renderer loads http://127.0.0.1:{port}
        → User interacts with the app
  → On quit, Electron kills the Python process
```

The key insight: we ship a complete, standalone Python + dependencies alongside
the Electron app using `extraResources`. The user never needs Python installed.

## Project Structure

```
├── frontend/              Electron app
│   ├── main.js            Main process — spawns Python, creates window
│   ├── preload.js         Context bridge for renderer
│   └── package.json       Electron + electron-builder config
├── backend/
│   ├── pyproject.toml     Python dependencies (managed by uv)
│   └── app/main.py        FastAPI application
├── build/
│   ├── build.sh           Unix build script
│   ├── build.bat          Windows build script
│   └── bundle/            (generated) Python runtime + deps
└── .github/workflows/
    └── build.yml          CI: builds for Linux, macOS (Intel+ARM), Windows
```

## Prerequisites

- [Node.js](https://nodejs.org/) >= 20
- [uv](https://docs.astral.sh/uv/) (recommended) or pip
- `curl` and `tar` (available by default on macOS/Linux; included in Windows 10+)

## Local Development

```bash
# 1. Build the Python bundle for your platform
chmod +x build/build.sh
./build/build.sh

# 2. Install Electron dependencies
cd frontend
npm install

# 3. Run the app
npm start
```

## Building for Distribution

### Locally

```bash
# Build Python bundle
./build/build.sh

# Build Electron distributable
cd frontend
npm run build
# Output in ../dist/
```

### Via GitHub Actions

Push a tag to trigger a release build for all platforms:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds for:
- **Linux x86_64** → `.AppImage`, `.deb`
- **macOS Intel** → `.dmg`
- **macOS Apple Silicon** → `.dmg`
- **Windows x86_64** → `.exe` (NSIS installer)

Artifacts are uploaded to the GitHub Release automatically.

## How the Bundling Works

1. **python-build-standalone** provides a pre-built, self-contained Python
   interpreter (~50MB compressed) with no system dependencies.

2. `uv pip install --target` installs all Python packages into a flat
   `site-packages` directory — no virtualenv activation needed.

3. `electron-builder` copies the Python runtime, site-packages, and backend
   code into the app's `resources/` directory via `extraResources`.

4. At runtime, `main.js` sets `PYTHONPATH` to point at the bundled
   site-packages and spawns the bundled Python interpreter directly.

## Customizing

### Adding Python dependencies

Edit `backend/pyproject.toml`, then rebuild:

```bash
cd backend
uv lock          # update uv.lock
cd ..
./build/build.sh # rebuild the bundle
```

### Code-signing (macOS/Windows)

Set these repository secrets for the GitHub Action:
- `MAC_CERTIFICATE` — Base64-encoded .p12 certificate
- `MAC_CERTIFICATE_PASSWORD` — Certificate password
- Windows: configure `win.certificateFile` in `package.json`

Uncomment the relevant lines in `build.yml`.

### Reducing bundle size

The build script already strips `__pycache__`, tests, tkinter, and
pip/setuptools. For further reduction:
- Use `install_only_stripped` PBS variants (already the default)
- Remove unused stdlib modules in the prune step
- Use `--no-binary :none:` if you don't need compiled extensions
