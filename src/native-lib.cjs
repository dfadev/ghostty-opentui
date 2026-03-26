const { platform, arch } = require("os")

function loadNativeModule() {
  const path = require("path")
  const dir = path.resolve(__dirname, "..")

  // Try development path first
  try {
    return require(path.join(dir, "zig-out", "lib", "ghostty-opentui.node"))
  } catch {}

  // Load platform-specific dist path (dynamic to avoid bundler resolving dead branches)
  const p = platform()
  const a = arch()
  const target = `${p}-${a}`

  if (p === "win32" && a !== "x64") return null

  try {
    return require(path.join(dir, "dist", target, "ghostty-opentui.node"))
  } catch {}

  throw new Error(`Unsupported platform: ${target}`)
}

const native = loadNativeModule()

module.exports = { native }
