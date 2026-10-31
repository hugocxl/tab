import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {checkout}=JSON.parse(readFileSync(resolve(root,'.work/source.json'),'utf8'));
const {chromium}=await import(pathToFileURL(resolve(checkout,'apps/web/node_modules/playwright/index.mjs')).href);
const directory=resolve(root,process.env.CONVERSATION_BUNDLE??'.work/theme-candidate');
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.wasm':'application/wasm','.woff2':'font/woff2','.woff':'font/woff','.svg':'image/svg+xml','.json':'application/json'};
const server=createServer((request,response)=>{const path=resolve(directory,'.'+decodeURIComponent(new URL(request.url,'http://localhost').pathname));if(!path.startsWith(directory+'/')&&path!==directory){response.writeHead(403);response.end();return;}const file=path===directory?resolve(directory,'index.html'):path;if(!existsSync(file)){response.writeHead(404);response.end();return;}response.setHeader('Content-Type',mime[extname(file)]??'application/octet-stream');response.end(readFileSync(file));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true});
const context=await browser.newContext({viewport:{width:900,height:1100}});
const page=await context.newPage();
const errors=[],network=[],failures=[],checks=[],consoleMessages=[];
page.on('console',message=>consoleMessages.push({type:message.type(),text:message.text()}));
page.on('pageerror',error=>errors.push(error.message));
page.on('request',request=>{if(!request.url().startsWith(origin)&&!request.url().startsWith('data:')&&!request.url().startsWith('blob:'))network.push(request.url());});
page.on('websocket',socket=>network.push(socket.url()));
const text='## Final result\n\nSelected quotation with **bold** and `inline code`, [Native link](#final-result).\n\n<span style="color:rgb(18, 52, 86)">Authored color</span>\n\n```swift\nlet value = 42\nprint(value)\n```\n\n```json\n{"key":"value","count":2}\n```\n\n| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |\n\nFormula $x^2$.';
const items=[
 {id:'u1',kind:'user',text:'Review the project and explain the result.',isComplete:true,attachments:[{id:'note1',name:'note.txt',mimeType:'text/plain',byteCount:12}]},
 {id:'a0',kind:'assistant',text:'Earlier finding in completed work.',isComplete:true},
 {id:'cmd1',kind:'tool',text:'printf hello',isComplete:true,tool:{name:'commandExecution',category:'command',presentation:'command',status:'completed',input:JSON.stringify({command:'printf hello'}),output:'\u001b[31mhello\u001b[0m\n\u001b[38;2;18;52;86mAuthored RGB\u001b[0m',exitCode:0,startedAt:'2026-10-31T10:00:01Z',completedAt:'2026-10-31T10:00:02Z'}},
 {id:'generic1',kind:'tool',text:'Inspect document',isComplete:true,tool:{name:'mcp__document__inspect',category:'other',presentation:'dynamicTool',status:'completed',input:'{"path":"note.txt"}',output:'{"summary":"generic output","count":2}',outputIsJSON:true,startedAt:'2026-10-31T10:00:02Z',completedAt:'2026-10-31T10:00:03Z'}},
 {id:'a1',kind:'assistant',text,isComplete:true},
];
const snapshot={bridgeVersion:1,connectionState:'live',sessionId:'session',projectId:'project',environmentId:'project',revision:1,theme:'light',cwd:'/workspace',items,turns:[{userItemID:'u1',startedAt:'2026-10-31T10:00:00Z',completedAt:'2026-10-31T10:00:04Z',status:'idle',checkpoint:{id:'checkpoint',files:[{path:'Sources/main.swift',additions:3,deletions:1},{path:'image.png'}],totalFiles:2,additions:3,deletions:1,truncated:false}}],status:'idle',messages:items.filter(item=>item.kind==='user'||item.kind==='assistant').map(item=>({id:item.id,role:item.kind,text:item.text})),font:{interfaceSize:16,promptSize:14,codeSize:13},settings:{mathRenderingEnabled:false},capabilities:{nativeActions:true,attachments:true,cite:true,runShellCommand:true,openToolDiff:true,openTurnDiff:true,openAttachment:true,downloadAttachment:true}};
await page.addInitScript(()=>{
 window.__bridge=[];window.__copies=[];window.__citations=[];
 window.prompt=(prompt,value)=>{if(prompt==='__tab_conversation_cite_v1__'){window.__citations.push(JSON.parse(value));return 'true';}return null;};
 window.webkit={messageHandlers:{tabConversation:{postMessage(message){window.__bridge.push(message);if(message.type!=='action')return;let result=true;if(message.action.kind==='copy'){window.__copies.push(message.action);}else if(message.action.kind==='loadTurnItem'){const id=message.action.itemId??message.action.input?.itemId;result={item:id==='cmd1'?{id,type:'command_execution',input:'printf hello',output:'\u001b[31mhello\u001b[0m\n\u001b[38;2;18;52;86mAuthored RGB\u001b[0m',exitCode:0,status:'completed'}:{id,type:'dynamic_tool',toolName:'mcp__document__inspect',input:{path:'note.txt'},output:{summary:'generic output',count:2},status:'completed'}};}queueMicrotask(()=>window.TabConversation?.resolve({requestId:message.requestId,ok:true,result}));}}}};
});

function palette(seed=0){
 const c=n=>`rgb(${n+seed}, ${n+seed+1}, ${n+seed+2})`;
 return {background:c(12),foreground:c(210),mutedForeground:c(140),dimForeground:c(100),surface:c(24),border:c(65),hover:c(35),accent:c(170),accentSoft:c(40),accentForeground:c(240),warning:c(180),danger:c(160),diffAdd:c(150),diffRemove:c(155),diffHunk:c(145),card:c(28),cardBorder:c(66),raised:c(30),floating:c(32),selection:'rgba(100, 110, 120, 0.2)',syntax:{foreground:c(205),keyword:c(190),string:c(120),number:c(130),type:c(115),function:c(160),attribute:c(175),comment:c(95),punctuation:c(185)},ansi16:Array.from({length:16},(_,i)=>c(70+i*3))};
}
snapshot.theme='dark';snapshot.palette=palette();
async function check(name,run){try{await run();checks.push(name);}catch(error){failures.push({name,error:String(error)});}}
try{
 await page.goto(origin,{waitUntil:'networkidle'});await page.waitForFunction(()=>window.TabConversation);
 await page.evaluate(snapshot=>{window.__snapshot=snapshot;window.TabConversation.update(snapshot);},snapshot);
 await page.getByRole('heading',{name:'Final result'}).waitFor({timeout:15000});
 await page.waitForFunction(()=>document.querySelector('pre code')?.textContent.includes('print(value)'));
 await page.waitForTimeout(500);
 await page.getByRole('button',{name:/Worked for|Completed work/i}).first().click();
 const grouped=page.getByRole('button',{name:/Ran 1 command and used 1 tool/i});if(await grouped.count())await grouped.first().click();
 await page.getByRole('button',{name:/printf hello/i}).first().click();
 await page.locator('[class~="max-h-80"]').getByText('hello',{exact:true}).first().waitFor();
 await page.getByRole('button',{name:/Mcp__document__inspect/i}).first().click();
 await page.waitForTimeout(300);
 async function assertColors(p){
  const results=await page.evaluate(p=>{
   function rgba(color){const canvas=document.createElement('canvas');canvas.width=1;canvas.height=1;const context=canvas.getContext('2d');context.fillStyle=color;context.fillRect(0,0,1,1);return Array.from(context.getImageData(0,0,1,1).data);}
   const root=document.querySelector('[data-assistant-citation-source="a1"]');
   const paragraph=Array.from(root.querySelectorAll('p')).find(el=>el.textContent.startsWith('Selected quotation'));
   const swift=root.querySelectorAll('pre')[0],json=root.querySelectorAll('pre')[1];
   const span=(parent,text)=>Array.from(parent.querySelectorAll('span')).find(el=>el.textContent===text);
   const samples=[];function compare(name,element,property,expected){if(!element)throw Error('Missing actual '+name);samples.push({name,actual:rgba(getComputedStyle(element)[property]),expected:rgba(expected)});}
   compare('user message card',document.querySelector('.bg-message'),'backgroundColor',p.surface);
   compare('heading',root.querySelector('h2'),'color',p.foreground);
   compare('prose',paragraph,'color',`color-mix(in oklab, ${p.foreground} 90%, transparent)`);
   compare('link',root.querySelector('a'),'color',p.accent);
   compare('table rule',root.querySelector('th'),'borderBottomColor',`color-mix(in oklab, ${p.border} 60%, transparent)`);
   compare('Swift keyword',span(swift,'let '),'color',p.syntax.keyword);
   compare('Swift number',span(swift,'42'),'color',p.syntax.number);
   compare('JSON key',span(json,'"key"'),'color',p.syntax.keyword);
   compare('JSON string',span(json,'"value"'),'color',p.syntax.string);
   compare('ANSI red',document.querySelector('span[style*="--tab-ansi-1"]'),'color',p.ansi16[1]);
   compare('authored explicit RGB',Array.from(document.querySelectorAll('span')).find(el=>el.textContent==='Authored RGB'),'color','rgb(18, 52, 86)');
   return samples;
  },p);
  for(const sample of results)assert.deepEqual(sample.actual,sample.expected,sample.name);
 }
 await check('first native palette colors actual prose/headings/link/table/Swift/JSON/ANSI while authored RGB stays intact',()=>assertColors(snapshot.palette));
 await check('actual source menu uses native floating surface and border',async()=>{
  await page.getByRole('button',{name:'Copy table',exact:true}).click();
  const menu=page.getByRole('menu');await menu.waitFor();
  const result=await menu.evaluate((el,p)=>{
   function rgba(color){const canvas=document.createElement('canvas');canvas.width=1;canvas.height=1;const context=canvas.getContext('2d');context.fillStyle=color;context.fillRect(0,0,1,1);return Array.from(context.getImageData(0,0,1,1).data);}
   const opacity=getComputedStyle(el).getPropertyValue('--glass-opacity').trim();
   return {actual:[rgba(getComputedStyle(el).backgroundColor),rgba(getComputedStyle(el).borderColor)],expected:[rgba(`color-mix(in srgb, ${p.floating} 18%, color-mix(in srgb, ${p.floating} ${opacity}, transparent))`),rgba(`color-mix(in srgb, ${p.foreground} 10%, transparent)`)]};
  },snapshot.palette);
  assert.deepEqual(result.actual,result.expected);
  await page.keyboard.press('Escape');
 });
 await check('same-mode live palette preserves actual DOM selection and expanded inspectors',async()=>{
  await page.evaluate(()=>{const heading=document.querySelector('[data-assistant-citation-source="a1"] h2');window.__heading=heading;const node=heading.firstChild;const range=document.createRange();range.setStart(node,0);range.setEnd(node,5);window.getSelection().removeAllRanges();window.getSelection().addRange(range);});
  const next={...snapshot,palette:palette(10)};
  await page.evaluate(next=>window.TabConversation.update(next),next);
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('a[href="#final-result"]')).color==='rgb(180, 181, 182)');
  await assertColors(next.palette);
  assert.equal(await page.evaluate(()=>window.__heading===document.querySelector('[data-assistant-citation-source="a1"] h2')),true);
  assert.equal(await page.evaluate(()=>window.getSelection().toString()),'Final');
  assert.equal(await page.locator('[data-v2-item-inspector="command_execution"]').count(),1);
  assert.equal(await page.locator('[data-v2-item-inspector="dynamic_tool"]').count(),1);
 });
}finally{
 const unexpectedDiagnostics=await page.evaluate(()=>window.__bridge.filter(message=>message.type==='error'||(message.type==='renderDiagnostic'&&message.scope!=='resize-observer')));
 errors.push(...unexpectedDiagnostics.map(message=>JSON.stringify(message)));
 const report={checks,failures,errors,network,unexpectedDiagnostics};const output=resolve(root,'.work/qa/native-palette');mkdirSync(output,{recursive:true});writeFileSync(resolve(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));await browser.close();server.close();
}
assert.deepEqual(failures,[]);assert.deepEqual(errors,[]);assert.deepEqual(network,[]);
