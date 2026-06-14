#!/usr/bin/env node
/**
 * Compile harness for CreditGraph contracts.
 * Usage: node compile.js [file1.sol file2.sol ...]
 * With no args, compiles every .sol under src/.
 * Resolves @openzeppelin imports and relative imports from disk.
 */
const fs = require("fs");
const path = require("path");
const solc = require("solc");

const ROOT = __dirname;
const SRC = path.join(ROOT, "src");
const NODE_MODULES = path.join(ROOT, "node_modules");

function walk(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else if (entry.name.endsWith(".sol")) acc.push(full);
  }
  return acc;
}

// Determine target files
let targets = process.argv.slice(2);
if (targets.length === 0) {
  targets = walk(SRC);
} else {
  targets = targets.map((t) => path.resolve(ROOT, t));
}

const sources = {};
for (const f of targets) {
  const rel = path.relative(ROOT, f);
  sources[rel] = { content: fs.readFileSync(f, "utf8") };
}

// Import resolver
function findImport(importPath) {
  try {
    let resolved;
    if (importPath.startsWith("@")) {
      resolved = path.join(NODE_MODULES, importPath);
    } else {
      // Will be resolved relative by solc against the importing file's dir;
      // solc passes already-joined paths here in practice. Try a few bases.
      if (fs.existsSync(importPath)) resolved = importPath;
      else if (fs.existsSync(path.join(ROOT, importPath)))
        resolved = path.join(ROOT, importPath);
      else resolved = path.join(ROOT, importPath);
    }
    return { contents: fs.readFileSync(resolved, "utf8") };
  } catch (e) {
    return { error: "File not found: " + importPath };
  }
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: {
      "*": { "*": ["abi", "evm.bytecode.object"] },
    },
  },
};

const output = JSON.parse(
  solc.compile(JSON.stringify(input), { import: findImport })
);

let errorCount = 0;
let warningCount = 0;
if (output.errors) {
  for (const err of output.errors) {
    if (err.severity === "error") {
      errorCount++;
      console.error("ERROR:", err.formattedMessage);
    } else {
      warningCount++;
      // Suppress noisy license/pragma warnings from node_modules
      if (!err.formattedMessage.includes("node_modules")) {
        console.warn("WARN:", err.formattedMessage);
      }
    }
  }
}

if (errorCount === 0) {
  const compiled = output.contracts || {};
  let count = 0;
  for (const file of Object.keys(compiled)) {
    if (file.startsWith("src/")) {
      for (const name of Object.keys(compiled[file])) {
        const bc = compiled[file][name].evm.bytecode.object;
        if (bc && bc.length > 0) count++;
      }
    }
  }
  console.log(`\n✅ COMPILED OK — ${count} contract(s), ${warningCount} warning(s)`);
  process.exit(0);
} else {
  console.error(`\n❌ ${errorCount} error(s), ${warningCount} warning(s)`);
  process.exit(1);
}
