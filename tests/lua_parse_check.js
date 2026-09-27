// Independent Lua 5.1 grammar validation using luaparse.
//
// `lua_syntax_check.js` is a self-contained lexer/block checker with no
// dependencies. This script is the second opinion: it runs a real Lua 5.1
// grammar parser over the same files, which catches anything a block-structure
// check cannot (bad expressions, malformed tables, invalid statements).
//
// luaparse is a dev-only dependency; install it where this script can resolve it:
//   npm install --prefix . luaparse
// or run with NODE_PATH pointing at an existing install.
//
// Usage: node tests/lua_parse_check.js <dir> [--strict]

const fs = require('fs');
const path = require('path');

let luaparse;
const candidates = [
  'luaparse',
  path.join(__dirname, '..', 'node_modules', 'luaparse'),
  path.join(process.env.TEMP || '/tmp', 'dsh-luaparse', 'node_modules', 'luaparse'),
];
let loadError = null;
for (const candidate of candidates) {
  try {
    luaparse = require(candidate);
    break;
  } catch (err) {
    loadError = err;
  }
}
if (!luaparse) {
  console.error('luaparse is not available. Install it with:');
  console.error('  npm install --prefix . luaparse');
  console.error('Last error: ' + (loadError && loadError.message));
  process.exit(2);
}

const root = process.argv[2];
if (!root) {
  console.error('usage: node lua_parse_check.js <dir>');
  process.exit(2);
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      walk(full, out);
    } else if (entry.name.endsWith('.lua')) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(root).sort();
let bad = 0;

for (const file of files) {
  const rel = path.relative(root, file);
  const src = fs.readFileSync(file, 'utf8');
  try {
    // luaVersion '5.1' matches LuaJIT, which is what Neovim embeds.
    luaparse.parse(src, {
      luaVersion: '5.1',
      comments: false,
      scope: false,
      locations: true,
    });
    console.log(`OK    ${rel}`);
  } catch (err) {
    bad++;
    const line = err.line !== undefined ? err.line : (err.index !== undefined ? err.index : '?');
    console.log(`FAIL  ${rel}`);
    console.log(`        ${err.message} (line ${line})`);
  }
}

console.log('');
console.log(`${files.length} files parsed as Lua 5.1, ${bad} failed`);
process.exit(bad === 0 ? 0 : 1);
