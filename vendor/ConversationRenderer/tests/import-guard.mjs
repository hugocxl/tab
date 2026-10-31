import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {rejectInvalidImports} from '../buildWarnings.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {checkout}=JSON.parse(readFileSync(resolve(root,'.work/source.json'),'utf8'));
const require=createRequire(resolve(checkout,'apps/web/package.json'));
const {build}=await import(pathToFileURL(resolve(checkout,'apps/web/node_modules/vite-plus/dist/index.js')).href);
let rejected=false;
try{await build({configFile:false,root,plugins:[{name:'invalid-effect-api-fixture',resolveId(id){if(id.endsWith('virtual:invalid-effect-api'))return '\0invalid-effect-api';if(id==='effect/Option')return require.resolve(id);},load(id){if(id==='\0invalid-effect-api')return 'import * as Option from "effect/Option";export const value=Option.fromNullable("fixture");';}}],build:{outDir:resolve(root,'.work/import-guard'),emptyOutDir:true,lib:{entry:'virtual:invalid-effect-api',formats:['es']},rollupOptions:{onwarn:rejectInvalidImports}}});}catch(error){assert.match(String(error),/Invalid renderer import \(IMPORT_IS_UNDEFINED\)/);rejected=true;}
assert.equal(rejected,true,'A nonexistent Effect namespace API must fail the build');
console.log('Undefined namespace import guard passed');
