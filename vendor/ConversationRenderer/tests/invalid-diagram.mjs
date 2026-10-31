import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {checkout}=JSON.parse(readFileSync(resolve(root,'.work/source.json'),'utf8'));
const {chromium}=await import(pathToFileURL(resolve(checkout,'apps/web/node_modules/playwright/index.mjs')).href);
const directory=resolve(root,process.env.CONVERSATION_BUNDLE??(process.env.CONVERSATION_SMOKE==='1'?'.work/smoke':'../../Sources/TabApp/Resources/ConversationRenderer'));
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.wasm':'application/wasm','.woff2':'font/woff2','.woff':'font/woff','.svg':'image/svg+xml','.json':'application/json'};
const server=createServer((request,response)=>{const path=resolve(directory,'.'+decodeURIComponent(new URL(request.url,'http://localhost').pathname));if(!path.startsWith(directory+'/')&&path!==directory){response.writeHead(403);response.end();return;}const file=path===directory?resolve(directory,'index.html'):path;if(!existsSync(file)){response.writeHead(404);response.end();return;}response.setHeader('Content-Type',mime[extname(file)]??'application/octet-stream');response.end(readFileSync(file));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true});
const context=await browser.newContext({viewport:{width:800,height:900}});
const page=await context.newPage();
const errors=[];page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
await page.addInitScript(()=>{window.__bridge=[];window.webkit={messageHandlers:{tabConversation:{postMessage(message){window.__bridge.push(message);if(message.type==='action')queueMicrotask(()=>window.TabConversation?.resolve({requestId:message.requestId,ok:false,error:'No native host in smoke test'}));}}}};});
try{
 await page.goto(`http://127.0.0.1:${server.address().port}/`,{waitUntil:'networkidle'});
 await page.waitForFunction(()=>window.TabConversation);
 const text='## Before diagram\n\n```mermaid\nflowchart LR\nA -->\n```\n\nAfter diagram.';
 await page.evaluate(text=>window.TabConversation.update({bridgeVersion:1,sessionId:'invalid-diagram',revision:1,theme:'light',items:[],turns:[],status:'idle',messages:[{id:'a',role:'assistant',text}],font:{interfaceSize:16,promptSize:14,codeSize:13},capabilities:{}}),text);
 await page.getByText('Unable to render diagram:',{exact:false}).waitFor();
 const result=await page.evaluate(()=>({before:document.body.innerText.includes('Before diagram'),after:document.body.innerText.includes('After diagram.'),sourceFallback:document.body.innerText.includes('Unable to render diagram:'),wholeBodyErrors:window.__bridge.filter(message=>message.type==='error')}));
 if(!result.before||!result.after||!result.sourceFallback||result.wholeBodyErrors.length||errors.length)throw new Error('Invalid source diagram replaced or damaged the conversation');
 const target=resolve(root,'.work/qa');mkdirSync(target,{recursive:true});writeFileSync(resolve(target,'invalid-diagram.json'),JSON.stringify({...result,errors},null,2));console.log(JSON.stringify({...result,errors},null,2));
}catch(error){console.error(JSON.stringify({error:String(error),errors,body:await page.locator('body').innerText(),bridge:await page.evaluate(()=>window.__bridge)},null,2));throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
