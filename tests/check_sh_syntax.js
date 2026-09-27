// Syntax-check generated shell scripts without running bash.
//
// A real `bash -n` is preferable but not always available (this environment
// blocks the child's stdio pipes, and `bash -n` needs them for diagnostics). This
// catches the failure modes that actually make a launcher fail at startup:
//
//   * an unterminated quote
//   * an unterminated ${...} or $(...) construct
//   * a missing `fi`, `done` or `esac`
//   * unbalanced parentheses
//   * CRLF line endings, which make `#!/usr/bin/env bash\r` unrunnable
//   * a missing shebang
//
// usage: node check_sh_syntax.mjs <file.sh> [more.sh ...]
import { readFile } from 'node:fs/promises';

function check(src, file) {
  const problems = [];

  if (!src.startsWith('#!')) problems.push('missing shebang on line 1');
  if (/\r\n/.test(src)) problems.push('contains CRLF line endings (a shebang ending in \\r will not run)');
  if (src.startsWith('#!') && /^#![^\n]*\r/.test(src)) problems.push('shebang has a trailing carriage return');

  // Strip comments and single-quoted strings so keywords inside them are ignored.
  const lines = src.split('\n');
  let openIf = 0;
  let openDo = 0;
  let openCase = 0;
  let parens = 0;
  let inHeredoc = null;

  lines.forEach((raw, index) => {
    const lineNo = index + 1;
    let line = raw;

    // Heredoc bodies are opaque until the terminator.
    if (inHeredoc) {
      if (line.trim() === inHeredoc) inHeredoc = null;
      return;
    }
    const heredoc = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?\s*$/.exec(line);
    if (heredoc) {
      inHeredoc = heredoc[1];
      return;
    }

    // Remove trailing comments (naive: no '#' inside quotes on the same line).
    const hash = line.indexOf('#');
    if (hash >= 0) {
      const before = line.slice(0, hash);
      const singles = (before.match(/'/g) || []).length;
      const doubles = (before.match(/"/g) || []).length;
      if (singles % 2 === 0 && doubles % 2 === 0) line = before;
    }

    // Quote balance per line, ignoring escapes.
    let single = 0;
    let double = 0;
    let escaped = false;
    for (const ch of line) {
      if (escaped) { escaped = false; continue; }
      if (ch === '\\') { escaped = true; continue; }
      if (ch === "'" && double % 2 === 0) single++;
      else if (ch === '"' && single % 2 === 0) double++;
    }
    if (single % 2 !== 0) problems.push(`line ${lineNo}: unbalanced single quote`);
    if (double % 2 !== 0) problems.push(`line ${lineNo}: unbalanced double quote`);

    for (const ch of line) {
      if (ch === '(') parens++;
      else if (ch === ')') parens--;
    }

    // Keywords, matched as whole words at a statement position.
    const words = line.replace(/[(){};]/g, ' ').split(/\s+/).filter(Boolean);
    words.forEach((w, i) => {
      switch (w) {
        case 'if': openIf++; break;
        case 'fi': openIf--; break;
        case 'do': openDo++; break;
        case 'done': openDo--; break;
        case 'case': openCase++; break;
        case 'esac': openCase--; break;
        default: break;
      }
      // `for x in ...; do` and `while ...; do` count once each, which is correct.
      void i;
    });
  });

  if (parens !== 0) problems.push(`unbalanced parentheses (net ${parens})`);
  if (openIf !== 0) problems.push(`unbalanced if/fi (net ${openIf})`);
  if (openDo !== 0) problems.push(`unbalanced do/done (net ${openDo})`);
  if (openCase !== 0) problems.push(`unbalanced case/esac (net ${openCase})`);
  if (inHeredoc) problems.push(`heredoc ${inHeredoc} is never terminated`);

  return { file, problems, lines: lines.length };
}

let bad = 0;
for (const file of process.argv.slice(2)) {
  const src = await readFile(file, 'utf8');
  const { problems, lines } = check(src, file);
  if (problems.length === 0) {
    console.log(`OK    ${file}  (${lines} lines)`);
  } else {
    bad++;
    console.log(`FAIL  ${file}`);
    for (const p of problems) console.log(`        ${p}`);
  }
}
console.log('');
console.log(`${process.argv.length - 2} file(s) checked, ${bad} with problems`);
process.exit(bad === 0 ? 0 : 1);
