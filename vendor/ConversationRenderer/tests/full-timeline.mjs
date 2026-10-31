import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {checkout}=JSON.parse(readFileSync(resolve(root,'.work/source.json'),'utf8'));
const {chromium}=await import(pathToFileURL(resolve(checkout,'apps/web/node_modules/playwright/index.mjs')).href);
const directory=resolve(root,process.env.CONVERSATION_BUNDLE??'.work/full');
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
try{
 await page.goto(origin,{waitUntil:'networkidle'});await page.waitForFunction(()=>window.TabConversation);
 await page.evaluate(snapshot=>{window.__snapshot=snapshot;window.TabConversation.update(snapshot);},snapshot);
 await page.getByRole('heading',{name:'Final result'}).waitFor({timeout:15000});
 await page.waitForSelector('pre');await page.waitForTimeout(400);
 await check('snapshot settings update false→true→false',async()=>{
  assert.equal(await page.locator('.katex').count(),0);
  await page.evaluate(()=>window.TabConversation.update({...window.__snapshot,revision:2,settings:{mathRenderingEnabled:true}}));
  await page.waitForSelector('.katex',{timeout:5000});
  await page.evaluate(()=>window.TabConversation.update({...window.__snapshot,revision:3,settings:{mathRenderingEnabled:false}}));
  await page.waitForFunction(()=>document.querySelectorAll('.katex').length===0);
 });
 await check('appearance changes after mount',async()=>{
  await page.evaluate(()=>window.TabConversation.update({...window.__snapshot,revision:4,theme:'dark'}));
  await page.waitForFunction(()=>document.documentElement.classList.contains('dark'));
  await page.evaluate(()=>window.TabConversation.update({...window.__snapshot,revision:5,theme:'light'}));
  await page.waitForFunction(()=>!document.documentElement.classList.contains('dark'));
 });
 await check('actual code copy emits raw code',async()=>{
  await page.getByRole('button',{name:'Copy code',exact:true}).click();
  await page.waitForFunction(()=>window.__copies.length>0);
  assert.equal(await page.evaluate(()=>window.__copies.at(-1).text),'let value = 42\nprint(value)\n');
 });
 await check('actual table Markdown and CSV menus',async()=>{
  await page.getByRole('button',{name:'Copy table',exact:true}).click();
  await page.getByRole('menuitem',{name:'Copy as Markdown',exact:true}).click();
  await page.waitForFunction(()=>window.__copies.at(-1)?.text?.includes('| Name |'));
  assert.equal(await page.evaluate(()=>window.__copies.at(-1).text),'| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |');
  await page.waitForTimeout(1250);
  await page.getByRole('button',{name:'Copy table',exact:true}).click();
  await page.getByRole('menuitem',{name:'Copy as CSV',exact:true}).click();
  await page.waitForFunction(()=>window.__copies.at(-1)?.text?.startsWith('Name,Value'));
  assert.equal(await page.evaluate(()=>window.__copies.at(-1).text),'Name,Value\nAlpha,12\nBeta,34');
 });
 await check('completed work expands actual command and generic inspectors',async()=>{
  await page.waitForTimeout(750); // Late first inspection must retain the authoritative atom even with no output subscriber.
  const toggle=page.getByRole('button',{name:/Worked for|Completed work/i}).first();
  await toggle.click();
  const grouped=page.getByRole('button',{name:/Ran 1 command and used 1 tool/i});
  if(await grouped.count())await grouped.first().click();
  await page.getByRole('button',{name:/printf hello/i}).first().click();
  await page.locator('[class~="max-h-80"]').getByText('hello',{exact:true}).first().waitFor();
  assert.equal(await page.locator('[class~="max-h-80"]').getByText('hello',{exact:true}).first().evaluate(node=>getComputedStyle(node).color),'rgb(207, 34, 46)');
  const generic=page.getByRole('button',{name:/Mcp__document__inspect/i}).first();
  await generic.click();await generic.getByText('path',{exact:true}).waitFor();
  assert.equal(await generic.getAttribute('aria-expanded'),'true');

 });
 await check('cross-section selected copy preserves prose, code, table and HTML',async()=>{
  const payload=await page.evaluate(()=>{
   const root=document.querySelector('[data-assistant-citation-source="a1"]');
   const first=Array.from(root.querySelectorAll('p')).find(node=>node.textContent.startsWith('Selected quotation'));
   const last=Array.from(root.querySelectorAll('td')).at(-1);
   const walker=document.createTreeWalker(first,NodeFilter.SHOW_TEXT),start=walker.nextNode();
   const endWalker=document.createTreeWalker(last,NodeFilter.SHOW_TEXT);let end=endWalker.nextNode(),next;while(next=endWalker.nextNode())end=next;
   const range=document.createRange();range.setStart(start,0);range.setEnd(end,end.textContent.length);
   const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
   const transfer=new DataTransfer(),event=new ClipboardEvent('copy',{bubbles:true,cancelable:true,clipboardData:transfer});
   first.dispatchEvent(event);return {plain:transfer.getData('text/plain'),html:transfer.getData('text/html')};
  });
  assert.ok(payload.plain.includes('**bold**'));assert.ok(payload.plain.includes('```swift\nlet value = 42\nprint(value)\n```'));
  assert.ok(payload.plain.includes('| **Alpha** | 12 |'));assert.ok(payload.html.includes('<strong>bold</strong>'));assert.ok(payload.html.includes('<table'));
 });
 await check('source Cite toolbar synchronously commits exact selector',async()=>{
  await page.evaluate(()=>{
   const root=document.querySelector('[data-assistant-citation-source="a1"]');const paragraph=Array.from(root.querySelectorAll('p')).find(node=>node.textContent.startsWith('Selected quotation'));
   paragraph.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,isPrimary:true}));
   const node=document.createTreeWalker(paragraph,NodeFilter.SHOW_TEXT).nextNode();const range=document.createRange();range.setStart(node,0);range.setEnd(node,'Selected quotation'.length);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
   const rect=range.getBoundingClientRect();paragraph.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,button:0,detail:1,clientX:rect.right,clientY:rect.bottom}));
  });
  await page.getByRole('button',{name:'Cite selection in composer',exact:true}).click();
  const citation=await page.evaluate(()=>window.__citations.at(-1));
  assert.equal(citation.text,'Selected quotation');assert.equal(citation.messageId,'a1');assert.equal(citation.threadId,'session');assert.equal(citation.environmentId,'project');
  assert.ok(Number.isInteger(citation.start));assert.ok(citation.end>citation.start);assert.ok(citation.prefix.length<=32&&citation.suffix.length<=32);
  assert.equal(await page.evaluate(()=>window.getSelection().isCollapsed),true);
  await page.evaluate(citation=>window.TabConversation.navigateCitation(citation),citation);
  await page.waitForFunction(()=>CSS.highlights?.has('tab-assistant-citation'));
 });
 await check('Go to source expands folded response and highlights exact quote',async()=>{
  const toggle=page.getByRole('button',{name:/Worked for|Completed work/i}).first();
  if(await toggle.getAttribute('aria-expanded')==='true')await toggle.click();
  const citation={version:1,environmentId:'project',threadId:'session',messageId:'a0',text:'Earlier finding',start:0,end:15,prefix:'',suffix:' in completed work.'};
  await page.evaluate(citation=>window.TabConversation.navigateCitation(citation),citation);
  await page.locator('[data-assistant-citation-source="a0"]').waitFor();
  await page.waitForFunction(()=>CSS.highlights?.get('tab-assistant-citation')?.size>0);
 });
 await check('retained binary diff counts never render NaN',async()=>{const body=await page.locator('body').innerText();assert.ok(body.includes('image.png'),'Binary file must be rendered for this assertion to be meaningful');assert.ok(!body.includes('NaN'));});
 await check('running command appends ANSI-styled output from the current native snapshot',async()=>{
  await page.evaluate(()=>{const current=window.__snapshot;const command=current.items.find(item=>item.id==='cmd1');window.__live={...current,revision:20,status:'working',items:[current.items[0],{...command,isComplete:false,tool:{...command.tool,status:'running',completedAt:undefined}}],messages:[current.messages[0]],turns:[{...current.turns[0],completedAt:undefined,status:'working',checkpoint:undefined}]};window.TabConversation.update(window.__live);});
  const command=page.getByRole('button',{name:/printf hello/i}).first();await command.waitFor();
  if(await command.getAttribute('aria-expanded')!=='true')await command.click();
  await page.locator('[class~="max-h-80"]').getByText('hello',{exact:true}).first().waitFor();
  await page.evaluate(()=>{const current=window.__live;window.TabConversation.update({...current,revision:21,items:current.items.map(item=>item.id==='cmd1'?{...item,tool:{...item.tool,output:item.tool.output+'\u001b[32mlive append\u001b[0m\n'}}:item)});});
  const appended=page.locator('[class~="max-h-80"]').getByText('live append',{exact:true}).first();await appended.waitFor();
  assert.equal(await appended.evaluate(node=>getComputedStyle(node).color),'rgb(17, 99, 41)');
 });
 await page.waitForTimeout(500);
 const output=resolve(root,'.work/qa/full-timeline');mkdirSync(output,{recursive:true});
 await page.screenshot({path:resolve(output,'full-timeline.png'),fullPage:true});
 const quietBefore=await page.evaluate(()=>{const viewport=document.querySelector('[data-assistant-citation-viewport]');const rect=viewport?.getBoundingClientRect();return {notices:window.__bridge.filter(message=>message.scope==='resize-observer').length,geometry:rect?{x:rect.x,y:rect.y,width:rect.width,height:rect.height,scrollHeight:viewport.scrollHeight,scrollTop:viewport.scrollTop}:null};});
 await page.waitForTimeout(500);
 const quietAfter=await page.evaluate(()=>{const viewport=document.querySelector('[data-assistant-citation-viewport]');const rect=viewport?.getBoundingClientRect();return {notices:window.__bridge.filter(message=>message.scope==='resize-observer').length,geometry:rect?{x:rect.x,y:rect.y,width:rect.width,height:rect.height,scrollHeight:viewport.scrollHeight,scrollTop:viewport.scrollTop}:null};});
 await check('source resize notifications and viewport geometry settle in a quiet window',async()=>{assert.deepEqual(quietAfter,quietBefore);assert.ok(quietAfter.geometry);});
 const diagnostics=await page.evaluate(()=>window.__bridge.filter(message=>message.type==='renderDiagnostic'||message.type==='error'));
 const unexpectedDiagnostics=diagnostics.filter(message=>!(message.type==='renderDiagnostic'&&message.scope==='resize-observer'&&/^ResizeObserver loop (?:completed with undelivered notifications\.?|limit exceeded\.?)$/.test(message.message)));
 const report={checks,failures,errors,network,diagnostics,unexpectedDiagnostics,quietBefore,quietAfter,consoleMessages,buttons:await page.getByRole('button').allTextContents(),body:await page.locator('body').innerText(),bridge:await page.evaluate(()=>window.__bridge),citations:await page.evaluate(()=>window.__citations)};
 writeFileSync(resolve(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
 if(failures.length||errors.length||network.length||unexpectedDiagnostics.length||consoleMessages.some(message=>message.type==='error'))process.exitCode=1;
}catch(error){if(await page.getByRole('button',{name:'Show Error',exact:true}).count())await page.getByRole('button',{name:'Show Error',exact:true}).click();console.error(JSON.stringify({error:String(error),errors,network,consoleMessages,body:await page.locator('body').innerText(),bridge:await page.evaluate(()=>window.__bridge)},null,2));throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
