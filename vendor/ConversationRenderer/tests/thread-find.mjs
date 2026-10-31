import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {checkout}=JSON.parse(readFileSync(resolve(root,'.work/source.json'),'utf8'));
const {chromium}=await import(pathToFileURL(resolve(checkout,'apps/web/node_modules/playwright/index.mjs')).href);
const directory=resolve(root,process.env.CONVERSATION_BUNDLE??'.work/find-candidate');
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
const text='## Final result\n\nSelected quotation with **bold** and `inline code`.\n\n```swift\nlet value = 42\nprint(value)\n```\n\n| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |\n\nFormula $x^2$.';
const items=[
 {id:'u1',kind:'user',text:'Review the project and explain the result.',isComplete:true,attachments:[{id:'note1',name:'note.txt',mimeType:'text/plain',byteCount:12}]},
 {id:'a0',kind:'assistant',text:'Earlier finding in completed work.',isComplete:true},
 {id:'cmd1',kind:'tool',text:'printf hello',isComplete:true,tool:{name:'commandExecution',category:'command',presentation:'command',status:'completed',input:JSON.stringify({command:'printf hello'}),output:'\u001b[31mhello\u001b[0m\n',exitCode:0,startedAt:'2026-10-31T10:00:01Z',completedAt:'2026-10-31T10:00:02Z'}},
 {id:'generic1',kind:'tool',text:'Inspect document',isComplete:true,tool:{name:'mcp__document__inspect',category:'other',presentation:'dynamicTool',status:'completed',input:'{"path":"note.txt"}',output:'{"summary":"generic output","count":2}',outputIsJSON:true,startedAt:'2026-10-31T10:00:02Z',completedAt:'2026-10-31T10:00:03Z'}},
 {id:'a1',kind:'assistant',text,isComplete:true},
];
const snapshot={bridgeVersion:1,connectionState:'live',sessionId:'session',projectId:'project',environmentId:'project',revision:1,theme:'light',cwd:'/workspace',items,turns:[{userItemID:'u1',startedAt:'2026-10-31T10:00:00Z',completedAt:'2026-10-31T10:00:04Z',status:'idle',checkpoint:{id:'checkpoint',files:[{path:'Sources/main.swift',additions:3,deletions:1},{path:'image.png'}],totalFiles:2,additions:3,deletions:1,truncated:false}}],status:'idle',messages:items.filter(item=>item.kind==='user'||item.kind==='assistant').map(item=>({id:item.id,role:item.kind,text:item.text})),font:{interfaceSize:16,promptSize:14,codeSize:13},settings:{mathRenderingEnabled:false},capabilities:{nativeActions:true,attachments:true,cite:true,runShellCommand:true,openToolDiff:true,openTurnDiff:true,openAttachment:true,downloadAttachment:true}};
await page.addInitScript(()=>{
 window.__bridge=[];window.__copies=[];window.__citations=[];
 window.prompt=(prompt,value)=>{if(prompt==='__tab_conversation_cite_v1__'){window.__citations.push(JSON.parse(value));return 'true';}return null;};
 window.webkit={messageHandlers:{tabConversation:{postMessage(message){window.__bridge.push(message);if(message.type!=='action')return;let result=true;if(message.action.kind==='copy'){window.__copies.push(message.action);}else if(message.action.kind==='loadTurnItem'){const id=message.action.itemId??message.action.input?.itemId;result={item:id==='cmd1'?{id,type:'command_execution',input:'printf hello',output:'\u001b[31mhello\u001b[0m\n',exitCode:0,status:'completed'}:{id,type:'dynamic_tool',toolName:'mcp__document__inspect',input:{path:'note.txt'},output:{summary:'generic output',count:2},status:'completed'}};}queueMicrotask(()=>window.TabConversation?.resolve({requestId:message.requestId,ok:true,result}));}}}};
});
async function check(name,run){try{await run();checks.push(name);}catch(error){failures.push({name,error:String(error),buttons:await page.getByRole('button').allTextContents(),body:await page.locator('body').innerText()});}}
try {
 const content='## Searchable result\n\nA **needle** appears here. Another NEEDLE follows.';
 const value={...snapshot,items:snapshot.items.filter(item=>item.id!=='generic1').map(item=>item.id==='a0'?{...item,text:'Hidden needle in earlier response.'}:item.id==='a1'?{...item,text:content}:item),capabilities:{nativeActions:true,focusComposer:true}};
 await page.goto(origin,{waitUntil:'networkidle'});await page.evaluate(value=>{window.__findSnapshot=value;window.TabConversation.update(value);},value);await page.getByRole('heading',{name:'Searchable result'}).waitFor();
 assert.equal(await page.evaluate(()=>window.TabConversation.find('open')),true);const input=page.getByRole('searchbox',{name:'Find in thread'});await input.waitFor();await page.waitForFunction(()=>document.activeElement?.getAttribute('aria-label')==='Find in thread');await input.fill('needle');
 const search=page.getByRole('search',{name:'Find in thread'});await page.waitForFunction(()=>document.querySelector('[role=search]')?.textContent.includes('/3'));await page.waitForFunction(()=>CSS.highlights.get('tab-thread-find-active')?.size>0);
 const first=await search.innerText();assert.equal(await page.evaluate(()=>window.TabConversation.find('next')),true);await page.waitForFunction(first=>document.querySelector('[role=search]').textContent.trim()!==first.trim(),first);assert.equal(await page.evaluate(()=>window.TabConversation.find('previous')),true);await page.waitForFunction(first=>document.querySelector('[role=search]').textContent.trim()===first.trim(),first);
 await input.fill('Hidden needle');await page.waitForFunction(()=>document.querySelector('[role=search]').textContent.includes('1/1'));await page.getByText('Hidden needle in earlier response.',{exact:true}).waitFor();await page.waitForFunction(()=>CSS.highlights.get('tab-thread-find-active')?.size>0);
 await input.fill('needle');await page.waitForFunction(()=>document.querySelector('[role=search]').textContent.includes('/3'));
 await page.evaluate(()=>{const current=window.__findSnapshot;const next={...current,revision:2,items:current.items.map(item=>item.id==='a1'?{...item,text:'No matching token remains.'}:item)};window.__findSnapshot=next;window.TabConversation.update(next);});await page.waitForFunction(()=>document.querySelector('[role=search]').textContent.includes('1/1'));
 await page.evaluate(()=>{const current=window.__findSnapshot;const next={...current,revision:3,items:current.items.map(item=>item.id==='a1'?{...item,text:'Fresh NEEDLE streamed.',isComplete:false}:item)};window.__findSnapshot=next;window.TabConversation.update(next);});await page.waitForFunction(()=>document.querySelector('[role=search]').textContent.includes('/2'));
 await page.evaluate(()=>window.TabConversation.update({...window.__findSnapshot,revision:4,connectionState:'cached'}));await page.waitForFunction(()=>document.querySelector('[role=search]').textContent.includes('/2'));
 await input.focus();await page.keyboard.press('Escape');await page.waitForFunction(()=>!document.querySelector('[data-thread-find-bar]'));assert.ok(await page.evaluate(()=>window.__bridge.some(message=>message.type==='action'&&message.action.kind==='focusComposer')));
 const bridge=await page.evaluate(()=>window.__bridge);assert.ok(!bridge.some(message=>message.type==='error'));assert.deepEqual(errors,[]);assert.deepEqual(network,[]);assert.ok(!bridge.some(message=>message.type==='action'&&/find|searchThread|orchestration/.test(message.action.kind)));
 const report={checks:['actual source find bar opens/focuses through native contract','source parse/count/navigation and CSS highlights','find reveals hidden completed response','stream edits invalidate current item cache without stale counts','retained find works offline','Escape closes and requests native composer focus','no remote index/backend requested'],errors,network,fatal:bridge.filter(message=>message.type==='error')};const output=resolve(root,'.work/qa/thread-find');mkdirSync(output,{recursive:true});writeFileSync(resolve(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
