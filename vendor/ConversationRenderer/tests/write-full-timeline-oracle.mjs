import { upstreamOracleImports } from "../transformSource.mjs";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const target = resolve(checkout, "apps/web/src/components/chat");
const snapshot = JSON.parse(readFileSync(resolve(root, "tests/timeline-corpus.json"), "utf8"));
const projector = readFileSync(resolve(root, "src/projectNativeSnapshot.ts"), "utf8")
  .replace(
    /import type \{ ConversationSnapshot \} from ["']\.\/bridge["'];/,
    "type ConversationSnapshot = any;",
  )
  .replaceAll("@conversation-source/session-logic", "../../session-logic")
  .replaceAll("@conversation-source/components/chat/MessagesTimeline.logic", "./MessagesTimeline.logic")
  .replaceAll("@conversation-source/types", "../../types");
writeFileSync(resolve(target, "TabNativeProjection.fixture.ts"), upstreamOracleImports(projector));
const script = `import {expect,it} from 'vite-plus/test';
import {page} from 'vite-plus/test/browser';
import {createRef} from 'react';
import {Atom,AsyncResult} from 'effect/reactivity';
import {appendTerminalOutput,EMPTY_TERMINAL_OUTPUT} from '@conversation/shared/terminalOutput';
import {render} from '../../../test/render';
import {MessagesTimeline} from './MessagesTimeline';
import {ChatCanvas} from './ChatCanvas';
import {createChatCanvasStore} from './canvasStore';
import {AppAtomRegistryProvider} from '../../rpc/atomRegistry';
import {applyAppearanceFontVariables} from '../../appearanceFonts';
import {setAppearanceMode} from '../../hooks/useTheme';
import {projectNativeSnapshot} from './TabNativeProjection.fixture';
import '~/index.css';
const baseSnapshot=${JSON.stringify(snapshot)};
for(const width of [360,800])for(const dark of [false,true])it('source full timeline '+width+' '+dark,async()=>{
 const prefix='parity-'+width+'-'+dark+'-';const snapshot={...baseSnapshot,sessionId:prefix+'thread',items:baseSnapshot.items.map(item=>({...item,id:prefix+item.id})),turns:baseSnapshot.turns.map(turn=>({...turn,userItemID:prefix+turn.userItemID})),messages:baseSnapshot.messages.map(message=>({...message,id:prefix+message.id}))};
 const notification=(event:ErrorEvent)=>{if(event.error==null&&event.message.startsWith('ResizeObserver loop'))event.preventDefault();};window.addEventListener('error',notification);
 await page.viewport(width,1100);setAppearanceMode(dark?'dark':'light');document.documentElement.classList.toggle('dark',dark);
 applyAppearanceFontVariables(document.documentElement,{sans:'',code:'',composer:'',sizeInterface:16,sizePrompt:14,sizeCode:13,smoothing:true,separate:false});
 const projection=projectNativeSnapshot(snapshot);
 const detail=Atom.family((itemId:string)=>Atom.make(AsyncResult.success({item:projection.toolItems.get(itemId)})));const output=Atom.family((itemId:string)=>Atom.make(AsyncResult.success({output:appendTerminalOutput(EMPTY_TERMINAL_OUTPUT,projection.toolItems.get(itemId)?.output??''),running:false})));
 const source={detail:(input:any)=>detail(input.itemId),commandOutput:(input:any)=>output(input.itemId)};
 const props:any={...projection,listRef:createRef(),turnItemSource:source,isWorking:false,routeThreadKey:'project:'+snapshot.sessionId,activeThreadEnvironmentId:'project',markdownCwd:'/workspace',workspaceRoot:'/workspace',resolvedTheme:dark?'dark':'light',timestampFormat:'locale',supportsConversationRollback:false,isRevertingCheckpoint:false,onOpenThread:()=>{},onRevertToTurnCount:()=>{},onImageExpand:()=>{},anchorMessageId:null,onAnchorReady:()=>{},onAnchorSizeChanged:()=>{},contentInsetEndAdjustment:0,emptyPlaceholderInset:0,liveFollowEnabled:true,onIsAtEndChange:()=>{}};
 const store=createChatCanvasStore();
 await using screen=await render(<div style={{height:'100vh',minHeight:0}} className="relative flex min-h-0 flex-col bg-background text-foreground"><AppAtomRegistryProvider><ChatCanvas store={store} threadRef={{environmentId:'project',threadId:snapshot.sessionId} as any} preview={null} composerOverlayElement={null}><div className="relative flex min-h-0 flex-1 flex-col bg-background"><MessagesTimeline {...props}/></div></ChatCanvas></AppAtomRegistryProvider></div>);
 await expect.element(screen.getByRole('heading',{name:'Final result'})).toBeVisible();await document.fonts.ready;await new Promise(resolve=>setTimeout(resolve,350));
 const capture=()=>{const viewport=screen.container.querySelector('[data-assistant-citation-viewport]')!;const origin=viewport.getBoundingClientRect();return {viewport:{width:origin.width,height:origin.height,scrollHeight:viewport.scrollHeight},rows:Array.from(viewport.querySelectorAll('[data-timeline-row-id]')).map(row=>({id:row.getAttribute('data-timeline-row-id'),kind:row.getAttribute('data-timeline-row-kind'),text:row.textContent,nodes:Array.from(row.querySelectorAll('p,h1,h2,h3,pre,table,button,[data-tool-group-scroll],.max-h-80')).map(node=>{const rect=node.getBoundingClientRect();return {tag:node.tagName,text:node.textContent,x:rect.x-origin.x,y:rect.y-origin.y,width:rect.width,height:rect.height};})}))};};
 await screen.getByRole('heading',{name:'Final result'}).hover();await new Promise(resolve=>setTimeout(resolve,250));
 const collapsed=capture();
 await page.screenshot({path:'__screenshots__/tab-full-source/'+width+'-'+dark+'-collapsed.png',element:screen.container});
 await screen.getByRole('button',{name:/Worked for|Completed work/i}).first().click();await screen.getByRole('button',{name:/Ran 1 command and used 1 tool/i}).click();await screen.getByRole('button',{name:/printf hello/i}).first().click();await expect.poll(()=>screen.container.querySelector('.max-h-80')).toBeTruthy();await new Promise(resolve=>setTimeout(resolve,350));
 await screen.getByRole('heading',{name:'Final result'}).hover();await new Promise(resolve=>setTimeout(resolve,250));
 await page.screenshot({path:'__screenshots__/tab-full-source/'+width+'-'+dark+'-expanded.png',element:screen.container});
 await expect(JSON.stringify({collapsed,expanded:capture()},null,2)).toMatchFileSnapshot('./__snapshots__/tab-full-source-'+width+'-'+dark+'.json');
 window.removeEventListener('error',notification);
});`;
writeFileSync(resolve(target, "TabFullTimelineSource.browser.test.tsx"), upstreamOracleImports(script));
console.log("Wrote source ChatCanvas + MessagesTimeline differential oracle");
