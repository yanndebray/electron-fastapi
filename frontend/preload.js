const { contextBridge } = require("electron");

contextBridge.exposeInMainWorld("api", {
  // Expose a safe subset of functionality to the renderer
  platform: process.platform,
});
