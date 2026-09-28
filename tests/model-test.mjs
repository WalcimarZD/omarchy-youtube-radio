// Teste headless da logica pura (Model.js) fora do shell Omarchy.
// Dev-only: nao e dependencia de runtime do plugin.
//   node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

const here = path.dirname(fileURLToPath(import.meta.url))
const source = readFileSync(path.join(here, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const selfTest = new Function(source + "\nreturn selfTest;")()
const failures = selfTest()

if (failures === "") {
  console.log("MODEL_SELFTEST_OK")
  process.exit(0)
}

console.error(failures)
process.exit(1)
