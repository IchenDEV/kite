const ext = globalThis.browser ?? globalThis.chrome;
const promiseAPI = typeof globalThis.browser !== "undefined";

function invoke(target, method, ...args) {
  if (promiseAPI) return target[method](...args);
  return new Promise((resolve, reject) => {
    target[method](...args, (value) => {
      const error = globalThis.chrome?.runtime?.lastError;
      if (error) reject(new Error(error.message));
      else resolve(value);
    });
  });
}

const port = document.querySelector("#port");
const secret = document.querySelector("#secret");
const takeOverDownloads = document.querySelector("#takeOverDownloads");
const status = document.querySelector("#status");

async function load() {
  const value = await invoke(ext.storage.local, "get", ["port", "secret", "takeOverDownloads"]);
  port.value = value.port || 29110;
  secret.value = value.secret || "";
  takeOverDownloads.checked = value.takeOverDownloads === true;
}

document.querySelector("#save").addEventListener("click", async () => {
  await invoke(ext.storage.local, "set", {
    port: Number(port.value),
    secret: secret.value.trim(),
    takeOverDownloads: takeOverDownloads.checked,
  });
  status.textContent = "Saved.";
});

document.querySelector("#test").addEventListener("click", async () => {
  try {
    const response = await fetch(`http://127.0.0.1:${Number(port.value)}/stat`, {
      headers: { Authorization: `Bearer ${secret.value.trim()}` },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = await response.json();
    status.textContent = `Connected. ${body.numActive || 0} active download(s).`;
  } catch (error) {
    status.textContent = `Connection failed: ${error.message}`;
  }
});

load();
