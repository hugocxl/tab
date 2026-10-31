import { upstreamOracleImports } from "../transformSource.mjs";
import { writeSourceContentConfig } from "./source-content-routes.mjs";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
writeSourceContentConfig(checkout);
const corpus = JSON.parse(readFileSync(resolve(root, "tests/corpus.json"), "utf8"));
const script = `import {expect,it,vi} from 'vite-plus/test';
import {page,commands} from 'vite-plus/test/browser';
declare module 'vite-plus/test/browser' { interface BrowserCommands { interceptReferencedContent:()=>Promise<void>; } }
import {render} from '../../../test/render';
import ChatMarkdown from '../ChatMarkdown';
import {applyAppearanceFontVariables} from '../../appearanceFonts';
import {setAppearanceMode} from '../../hooks/useTheme';
import '~/index.css';
vi.mock(import('../../hooks/useSettings'),async original=>{const actual=await original();return {...actual,useClientSettings:(selector:any)=>selector({...actual.getClientSettings(),mathRenderingEnabled:true})};});
const corpus=${JSON.stringify(corpus)};
for(const width of [360,800])for(const dark of [false,true])it('source corpus '+width+' '+dark,async()=>{
 await commands.interceptReferencedContent();
 await page.viewport(width,1100);setAppearanceMode(dark?'dark':'light');document.documentElement.classList.toggle('dark',dark);
 applyAppearanceFontVariables(document.documentElement,{sans:'',code:'',composer:'',sizeInterface:16,sizePrompt:14,sizeCode:13,smoothing:true,separate:false});
 const results=[];
 for(const fixture of corpus){
  await using screen=await render(<ChatMarkdown cwd={undefined} text={fixture.text} parseRawHtml={fixture.role==='assistant'} lineBreaks={fixture.role==='user'} isStreaming={fixture.isStreaming}/>);
  await document.fonts.ready;
  if(fixture.name==='math-diagram-syntax'){await expect.poll(()=>screen.container.querySelector('.katex')).toBeTruthy();await expect.poll(()=>screen.container.querySelector('[data-markdown-mermaid] svg')).toBeTruthy();}
  await expect.poll(()=>Array.from(screen.container.querySelectorAll<HTMLImageElement>('img')).every(image=>image.complete&&image.naturalWidth>0)).toBe(true);
  await new Promise(resolve=>setTimeout(resolve,100));
  const root=screen.container.querySelector('.chat-markdown')!;const origin=root.getBoundingClientRect();
  const nodes=Array.from(root.querySelectorAll('p,h1,h2,h3,ul,ol,li,blockquote,table,th,td,details,summary,pre,code,a[id],.katex,[data-markdown-mermaid]')).map(node=>{const rect=node.getBoundingClientRect();return {tag:node.tagName,id:node.id||undefined,text:node.textContent,x:rect.x-origin.x,y:rect.y-origin.y,width:rect.width,height:rect.height};});
  results.push({name:fixture.name,text:root.textContent,nodes});
  await page.screenshot({path:'__screenshots__/tab-source-corpus/'+fixture.name+'-'+width+'-'+dark+'.png',element:screen.container});
 }
 await expect(JSON.stringify(results,null,2)).toMatchFileSnapshot('./__snapshots__/tab-source-corpus-'+width+'-'+dark+'.json');
});`;
writeFileSync(
  resolve(checkout, "apps/web/src/components/chat/TabSourceCorpus.browser.test.tsx"),
  upstreamOracleImports(script),
);
console.log("Wrote actual-source fixture corpus");
