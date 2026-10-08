// Source-level localization verification for PrtEasyBAK.cpp.
// 1) every UiText call site carries English + Traditional + Simplified and is a plain literal
// 2) every Simplified argument matches tools/zh-CN.json exactly
// 3) no user-visible CJK literal is left outside UiText()/BuildAboutText()
// Exit code 0 = pass.
'use strict';
const fs = require('fs');
const path = require('path');

const cppPath = path.join(__dirname, '..', 'PrtEasyBAK.cpp');
const src = fs.readFileSync(cppPath, 'utf8');
const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, 'zh-CN.json'), 'utf8')).translations;

function lineOf(index) { let l = 1; for (let i = 0; i < index; ++i) if (src[i] === '\n') ++l; return l; }
function unescapeWide(raw) {
  let out = '';
  for (let i = 0; i < raw.length; ++i) {
    const c = raw[i];
    if (c !== '\\') { out += c; continue; }
    const d = raw[++i];
    switch (d) {
      case 'n': out += '\n'; break; case 'r': out += '\r'; break; case 't': out += '\t'; break;
      case '0': out += '\0'; break; case '\\': out += '\\'; break; case '"': out += '"'; break;
      case "'": out += "'"; break;
      case 'u': out += String.fromCharCode(parseInt(raw.substr(i + 1, 4), 16)); i += 4; break;
      default: out += '\\' + d; break;
    }
  }
  return out;
}
function splitArgs(open) {
  let depth = 0, i = open + 1, args = [], inStr = false, inChr = false, start = i;
  for (; i < src.length; ++i) {
    const c = src[i];
    if (inStr) { if (c === '\\') { ++i; continue; } if (c === '"') inStr = false; continue; }
    if (inChr) { if (c === '\\') { ++i; continue; } if (c === "'") inChr = false; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === "'") { inChr = true; continue; }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') ++i; continue; }
    if (c === '(' || c === '[' || c === '{') { depth++; continue; }
    if (c === ')' || c === ']' || c === '}') {
      if (depth === 0 && c === ')') { args.push([start, i]); return args; }
      depth--; continue;
    }
    if (c === ',' && depth === 0) { args.push([start, i]); start = i + 1; continue; }
  }
  return null;
}

const literalRe = /^L"((?:[^"\\]|\\.)*)"$/;
const problems = [];
const consumed = [];
let siteCount = 0;
const seen = new Map();
const re = /UiText\s*\(/g;
let m;
while ((m = re.exec(src)) !== null) {
  if (/const\s+wchar_t\*\s*$/.test(src.slice(Math.max(0, m.index - 40), m.index))) continue; // definition
  const args = splitArgs(m.index + m[0].length - 1);
  const line = lineOf(m.index);
  siteCount++;
  if (!args || args.length !== 3) { problems.push('line ' + line + ': expected 3 arguments, got ' + (args ? args.length : 'parse failure')); continue; }
  const texts = args.map(a => src.slice(a[0], a[1]).trim());
  const lits = texts.map(t => literalRe.exec(t));
  if (lits.some(l => !l)) { problems.push('line ' + line + ': non-literal argument'); continue; }
  consumed.push(args.map(a => [a[0], a[1]]));
  const [en, tw, cn] = lits.map(l => unescapeWide(l[1]));
  if (!en) problems.push('line ' + line + ': empty English text');
  if (!tw) problems.push('line ' + line + ': empty Traditional Chinese text');
  if (!cn) problems.push('line ' + line + ': empty Simplified Chinese text');
  if (cn === en && en !== 'PrtEasyBAK') problems.push('line ' + line + ': Simplified text identical to English (' + JSON.stringify(en) + ')');
  const expected = catalog[en];
  if (expected === undefined) problems.push('line ' + line + ': English string missing from zh-CN.json: ' + JSON.stringify(en));
  else if (expected !== cn) problems.push('line ' + line + ': Simplified text differs from zh-CN.json for ' + JSON.stringify(en));
  if (!seen.has(en)) seen.set(en, new Set());
  seen.get(en).add(cn);
}
for (const [en, set] of seen) if (set.size > 1) problems.push('English string has inconsistent Simplified text: ' + JSON.stringify(en));

// CJK literals not consumed by a UiText call and not part of BuildAboutText
const aboutStart = src.indexOf('std::wstring BuildAboutText()');
const aboutEnd = src.indexOf('void ResetDialogFonts()');
consumed.push([[aboutStart, aboutEnd]]);
const litRe2 = /L"((?:[^"\\]|\\.)*)"/g;
const flaggedCjk = [];
let mm;
while ((mm = litRe2.exec(src)) !== null) {
  const start = mm.index, end = mm.index + mm[0].length;
  if (consumed.some(spans => spans.some(([a, b]) => start >= a && end <= b))) continue;
  const value = unescapeWide(mm[1]);
  if (/[\u3400-\u9FFF\uF900-\uFAFF]/.test(value)) flaggedCjk.push({ line: lineOf(start), text: value });
}

// 92 original call sites plus 23 added for the previously hardcoded Chinese error fragments,
// the sentence-final period, and the localized window title.
const EXPECTED_SITES = 115;
console.log('UiText call sites: ' + siteCount + ' (expected ' + EXPECTED_SITES + ')');
console.log('distinct English strings: ' + seen.size);
console.log('CJK literals outside UiText/BuildAboutText: ' + flaggedCjk.length + ' (expected 8)');

// These few literals are Chinese by design and are not UI text that needs a third language:
//  - the font-rendering samples used to pick a CJK-capable font
//  - the PrtEasyBAK.ini comment template (already trilingual)
//  - the language combo entries, each shown in its own script
const expectedCjk = new Set(['備份還原印表機', '备份恢复打印机', '简体中文', '繁體中文']);
const expectedCjkPrefix = ['; ui_lang='];
for (const f of flaggedCjk) {
  const known = expectedCjk.has(f.text) || expectedCjkPrefix.some(p => f.text.startsWith(p));
  console.log('  ' + (known ? '[expected]  ' : '[UNEXPECTED]') + ' line ' + f.line + ': ' + JSON.stringify(f.text));
  if (!known) problems.push('line ' + f.line + ': Chinese literal outside UiText/BuildAboutText: ' + JSON.stringify(f.text));
}
if (flaggedCjk.length !== 8) problems.push('expected 8 known non-UiText Chinese literals, found ' + flaggedCjk.length);

if (problems.length) {
  console.log('\nPROBLEMS (' + problems.length + '):');
  for (const p of problems) console.log('  ' + p);
} else {
  console.log('\nno problems found');
}
const ok = problems.length === 0 && siteCount === EXPECTED_SITES;
console.log(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
process.exit(ok ? 0 : 1);
