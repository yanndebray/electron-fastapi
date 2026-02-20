const { app, BrowserWindow } = require("electron");
const { spawn } = require("child_process");
const path = require("path");
const net = require("net");

let pythonProcess = null;
let mainWindow = null;

// ---------- helpers ----------

/** Find a free port by briefly opening and closing a server. */
function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on("error", reject);
  });
}

/** Resolve the path to the bundled Python interpreter. */
function getPythonPath() {
  const resourcesPath = app.isPackaged
    ? process.resourcesPath
    : path.join(__dirname, "..", "build", "bundle");

  const pythonDir = path.join(resourcesPath, "python-runtime");

  switch (process.platform) {
    case "win32":
      return path.join(pythonDir, "python.exe");
    case "darwin":
    case "linux":
      return path.join(pythonDir, "bin", "python3");
    default:
      throw new Error(`Unsupported platform: ${process.platform}`);
  }
}

/** Resolve the path to the backend app. */
function getBackendPath() {
  // Backend source lives at project root, not in the bundle
  const resourcesPath = app.isPackaged
    ? process.resourcesPath
    : path.join(__dirname, "..");

  return path.join(resourcesPath, "backend", "app", "main.py");
}

/** Wait until the FastAPI server is accepting connections. */
function waitForServer(port, timeoutMs = 15000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tryConnect = () => {
      const sock = new net.Socket();
      sock
        .once("connect", () => {
          sock.destroy();
          resolve();
        })
        .once("error", () => {
          sock.destroy();
          if (Date.now() - start > timeoutMs) {
            reject(new Error("Backend failed to start within timeout"));
          } else {
            setTimeout(tryConnect, 200);
          }
        })
        .connect(port, "127.0.0.1");
    };
    tryConnect();
  });
}

// ---------- lifecycle ----------

async function startBackend() {
  const port = await getFreePort();
  const pythonPath = getPythonPath();
  const backendPath = getBackendPath();

  // The PYTHONPATH ensures imports work when running from the bundled venv
  const env = {
    ...process.env,
    PYTHONDONTWRITEBYTECODE: "1",
  };

  // If we have a bundled venv site-packages, prepend it
  const bundlePath = app.isPackaged
    ? process.resourcesPath
    : path.join(__dirname, "..", "build", "bundle");
  // On bundled builds, we set PYTHONPATH to include the venv's site-packages
  // The build script flattens it so we can just point at the directory
  env.PYTHONPATH = path.join(bundlePath, "python-venv", "site-packages");

  console.log(`Starting backend: ${pythonPath} ${backendPath} ${port}`);

  pythonProcess = spawn(pythonPath, [backendPath, String(port)], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  pythonProcess.stdout.on("data", (d) => console.log(`[py] ${d}`));
  pythonProcess.stderr.on("data", (d) => console.error(`[py] ${d}`));
  pythonProcess.on("exit", (code) => {
    console.log(`Python exited with code ${code}`);
    pythonProcess = null;
  });

  await waitForServer(port);
  return port;
}

function stopBackend() {
  if (pythonProcess) {
    console.log("Stopping Python backend…");
    pythonProcess.kill();
    pythonProcess = null;
  }
}

async function createWindow(port) {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  // In production you'd load a built frontend; for dev, point at the backend or a local file
  await mainWindow.loadURL(`http://127.0.0.1:${port}/api/health`);
}

// ---------- app events ----------

app.whenReady().then(async () => {
  try {
    const port = await startBackend();
    await createWindow(port);
  } catch (err) {
    console.error("Failed to start:", err);
    app.quit();
  }
});

app.on("window-all-closed", () => {
  stopBackend();
  app.quit();
});

app.on("before-quit", stopBackend);
