import {expect,it} from 'vite-plus/test';
import {createRef} from 'react';
import * as Schema from 'effect/Schema';
import {OrchestrationV2TurnItem, EnvironmentId} from '@conversation/contracts';
import {render} from '../../../test/render';
import {MessagesTimeline} from './MessagesTimeline';
import {WorkLogRow,WorkLogDetails} from './WorkLog';
import {V2ItemInspector} from './V2ItemInspector';
import {projectNativeSnapshot} from '__TAB_NATIVE_PROJECTION_MODULE__';
import '~/index.css';
const time='2026-10-31T12:00:00Z';
const raw=(id:string,tool:Record<string,unknown>)=>({id,kind:'tool',text:id,isComplete:true,tool:{status:'completed',startedAt:time,completedAt:time,...tool}});
const cases=[
 raw('command',{category:'command',presentation:'command',input:'echo hello',output:'hello',exitCode:0}),
 raw('change',{category:'edit',presentation:'fileChange',fileChangeDetails:{fileName:'a.swift',diff:'-a\n+b',additions:1,deletions:1,operations:[{operation:'update',path:'a.swift'}]}}),
 raw('search',{category:'search',presentation:'fileSearch',fileSearchDetails:{pattern:'needle',results:[{fileName:'a.swift',line:4,column:2,preview:'needle'}]}}),
 raw('web',{category:'web',presentation:'webSearch',searchPatterns:['native'],webResults:[{title:'Native tools',url:'https://example.com/native',snippet:'Native result'}]}),
 raw('dynamic',{category:'other',presentation:'dynamicTool',name:'mcp.inspect',input:'{"z":1,"a":null}',output:'{"ok":true}',outputIsJSON:true}),
 {id:'approval',kind:'approval',text:'echo trusted',detail:'Approve command',isComplete:false},
 {id:'notice',kind:'notice',text:'Connection restored',isComplete:true},
];
const snapshot:any={bridgeVersion:1,sessionId:'thread',revision:1,theme:'light',status:'idle',font:{interfaceSize:16,promptSize:14,codeSize:13},messages:[],turns:[],items:cases};
it('validates projected native tools against the actual pinned source schema',async()=>{
 const projected=projectNativeSnapshot(snapshot);
 const encode=Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem));
 for(const item of projected.toolItems.values())expect(()=>encode(item)).not.toThrow();
 expect(projected.pendingApprovals[0]?.requestKind).toBe('command');
 expect(projected.timelineEntries.map((entry:any)=>entry.entry?.itemType)).toEqual(['command_execution','file_change','file_search','web_search','dynamic_tool','approval_request','system_notice']);
 expect(projected.toolItems.get('dynamic').input).toEqual({z:1,a:null});
 expect(projected.toolItems.get('dynamic').output).toEqual({ok:true});
});
it('renders source typed work inspectors with native projected data',async()=>{
 const projected=projectNativeSnapshot(snapshot);
 for(const id of ['command','change','search','web','dynamic']){
  const item=(projected.timelineEntries.find(entry=>entry.id===id)as any).entry.projectedItem;
  await using screen=await render(<WorkLogRow label={id}><WorkLogDetails kind="panel"><V2ItemInspector environmentId={EnvironmentId.make('fixture')} projectedItem={item}/></WorkLogDetails></WorkLogRow>);
  const expected:Record<string,string>={command:'hello',change:'a.swift',search:'needle',web:'Native result',dynamic:'"ok"'};
  await expect.element(screen.getByText(expected[id]!,{exact:false}).first()).toBeVisible();
 }
});
it('renders legacy untimed messages and source tool groups without epoch labels',async()=>{
 const projected=projectNativeSnapshot({...snapshot,items:[{id:'user',kind:'user',text:'Inspect',isComplete:true},...cases.slice(0,2),{id:'answer',kind:'assistant',text:'Done',isComplete:true}],turns:[]});
 const entries=projected.timelineEntries;
 expect((entries[0] as any).createdAt).toBe('');
 await using screen=await render(<div style={{height:600,width:800}}><MessagesTimeline {...projected} listRef={createRef()} routeThreadKey="fixture:thread" onOpenThread={()=>{}} supportsConversationRollback={false} onRevertToTurnCount={()=>{}} isRevertingCheckpoint={false} onImageExpand={()=>{}} activeThreadEnvironmentId={EnvironmentId.make('fixture')} markdownCwd={undefined} resolvedTheme="light" timestampFormat="locale" workspaceRoot={undefined} anchorMessageId={null} onAnchorReady={()=>{}} onAnchorSizeChanged={()=>{}} contentInsetEndAdjustment={0} emptyPlaceholderInset={0} liveFollowEnabled={false} onIsAtEndChange={()=>{}}/></div>);
 await expect.element(screen.getByText('Done',{exact:true})).toBeVisible();
 expect(screen.container.textContent).not.toContain('1970');
});

it('projects accepted native turn identity and keeps binary counts unknown',async()=>{
 const turn={userItemID:'prompt',startedAt:time,completedAt:'2026-10-31T12:01:05Z',status:'idle',outcome:'completed',checkpoint:{id:'recorded-checkpoint',files:[{path:'image.png'},{path:'a.swift',additions:2,deletions:1}],totalFiles:2,additions:2,deletions:1}};
 const projected=projectNativeSnapshot({...snapshot,turns:[turn],items:[{id:'prompt',kind:'user',text:'Inspect',isComplete:true},cases[0],{id:'answer',kind:'assistant',text:'Finished',isComplete:true}]});
 expect(projected.latestRun).toMatchObject({runId:'native-turn:prompt',status:'completed',startedAt:time,completedAt:turn.completedAt});
 expect(projected.turnDiffSummaries[0]?.files[0]?.additions).toBeUndefined();
 expect(projected.turnDiffSummaries[0]?.filesTotal).toEqual({count:2,additions:2,deletions:1});
 const answer:any=projected.timelineEntries.at(-1);
 expect(answer.message.createdAt).toBe(turn.completedAt);
 const {buildTurnDiffTree}=await import('../../lib/turnDiffTree');
 const tree=buildTurnDiffTree(projected.turnDiffSummaries[0]!.files);
 expect(tree.find(node=>node.name==='image.png')?.stat).toBeNull();
});

it('renders source live group and reveals the retained command inspector',async()=>{
 const active:any={...snapshot,status:'working',turns:[{userItemID:'prompt',startedAt:time,status:'working'}],items:[{id:'prompt',kind:'user',text:'Inspect',isComplete:true},raw('running',{category:'command',presentation:'command',input:'echo hello',output:'live output',status:'running'})]};
 active.items[1].isComplete=false;
 const projected=projectNativeSnapshot(active);
 const props:any={...projected,listRef:createRef(),routeThreadKey:'fixture:live-command',onOpenThread:()=>{},supportsConversationRollback:false,onRevertToTurnCount:()=>{},isRevertingCheckpoint:false,onImageExpand:()=>{},activeThreadEnvironmentId:EnvironmentId.make('fixture'),markdownCwd:undefined,resolvedTheme:'light',timestampFormat:'locale',workspaceRoot:undefined,anchorMessageId:null,onAnchorReady:()=>{},onAnchorSizeChanged:()=>{},contentInsetEndAdjustment:0,emptyPlaceholderInset:0,liveFollowEnabled:false,onIsAtEndChange:()=>{}};
 await using screen=await render(<div style={{height:600,width:800}}><MessagesTimeline {...props}/></div>);
 const running=screen.getByRole('button',{name:'Running echo',exact:true});
 await expect.element(running).toBeVisible();
 await running.click();
 expect(screen.container.textContent).not.toContain('live output');
 const command=screen.getByRole('button',{name:'echo hello',exact:true});
 await expect.element(command).toBeVisible();
 await command.click();
 await expect.element(screen.getByText('live output',{exact:true})).toBeVisible();
});

it('retains observed interruption before tools and does not infer legacy idle outcome',()=>{
 const stopped=projectNativeSnapshot({...snapshot,status:'idle',turns:[{userItemID:'p',startedAt:time,completedAt:time,status:'idle',outcome:'interrupted'}],items:[{id:'p',kind:'user',text:'Stop before tools',isComplete:true}]});
 expect(stopped.latestRun?.status).toBe('interrupted');
 const legacy=projectNativeSnapshot({...snapshot,status:'idle',turns:[{userItemID:'p',startedAt:time,completedAt:time,status:'idle'}],items:[{id:'p',kind:'user',text:'Unknown old outcome',isComplete:true}]});
 expect(legacy.latestRun).toBeNull();
 const approvals=projectNativeSnapshot({...snapshot,items:[{id:'approval:provider-id',kind:'approval',text:'Approve',isComplete:false}]});
 expect(approvals.pendingApprovals[0]?.requestId).toBe('approval:provider-id');
 expect(approvals.pendingApprovals[0]?.options?.map(option=>option.decision)).toEqual(['decline','accept']);
});

it('renders historic turn durations from actual prompt and terminal message times',async()=>{
 const turns=[{userItemID:'p1',startedAt:'2026-10-31T12:00:00Z',completedAt:'2026-10-31T12:01:05Z',status:'idle',outcome:'completed'},
 {userItemID:'p2',startedAt:'2026-10-31T12:02:00Z',completedAt:'2026-10-31T12:02:17Z',status:'idle',outcome:'completed'},
 {userItemID:'p3',startedAt:'2026-10-31T12:03:00Z',status:'working'}];
 const items=[{id:'p1',kind:'user',text:'First',isComplete:true},raw('c1',{category:'command',presentation:'command',input:'echo first',output:'first'}),{id:'a1',kind:'assistant',text:'First answer',isComplete:true},
 {id:'p2',kind:'user',text:'Second',isComplete:true},raw('c2',{category:'command',presentation:'command',input:'echo second',output:'second'}),{id:'a2',kind:'assistant',text:'Second answer',isComplete:true},
 {id:'p3',kind:'user',text:'Third',isComplete:true}];
 const projected=projectNativeSnapshot({...snapshot,status:'working',turns,items});
 const props:any={...projected,listRef:createRef(),routeThreadKey:'fixture:historic-timing',onOpenThread:()=>{},supportsConversationRollback:false,onRevertToTurnCount:()=>{},isRevertingCheckpoint:false,onImageExpand:()=>{},activeThreadEnvironmentId:EnvironmentId.make('fixture'),markdownCwd:undefined,resolvedTheme:'light',timestampFormat:'locale',workspaceRoot:undefined,anchorMessageId:null,onAnchorReady:()=>{},onAnchorSizeChanged:()=>{},contentInsetEndAdjustment:0,emptyPlaceholderInset:0,liveFollowEnabled:false,onIsAtEndChange:()=>{}};
 await using screen=await render(<div style={{height:1000,width:800}}><MessagesTimeline {...props}/></div>);
 const {formatDuration}=await import('@conversation/shared/orchestrationTiming');
 await expect.element(screen.getByText('Worked for '+formatDuration(65000),{exact:true})).toBeVisible();
 await expect.element(screen.getByText('Worked for '+formatDuration(17000),{exact:true})).toBeVisible();
});

it('keeps repeated native attachment IDs scoped to their source messages',()=>{
 const descriptor={id:'shared',name:'image.png',mimeType:'image/png',byteCount:10};
 const projected=projectNativeSnapshot({...snapshot,items:[{id:'first',kind:'user',text:'One',attachments:[{...descriptor,bridgeId:'scoped-first'}]},{id:'second',kind:'user',text:'Two',attachments:[{...descriptor,bridgeId:'scoped-second'}]}]});
 const messages=projected.timelineEntries as any[];
 expect(messages.map(entry=>entry.message.attachments[0].id)).toEqual(['scoped-first','scoped-second']);
 expect(projected.attachmentOwners.get('scoped-first')).toMatchObject({itemId:'first',attachmentId:'shared'});
 expect(projected.attachmentOwners.get('scoped-second')).toMatchObject({itemId:'second',attachmentId:'shared'});
 expect(projected.attachmentOwners.get('scoped-first')?.url).not.toBe(projected.attachmentOwners.get('scoped-second')?.url);
});

it('uses official source work labels, lifecycle and observed follow identities',async()=>{
 const source=await import('../../session-logic');
 const active:any={...snapshot,connectionState:'live',status:'working',turns:[{userItemID:'prompt',startedAt:time,status:'working'}],items:[
  {id:'prompt',kind:'user',text:'Inspect',isComplete:true,createdAt:time},
  {...raw('exit',{category:'command',presentation:'command',input:'false',exitCode:1,status:'failed'}),workContext:{providerTurnID:'provider-real',sourceStatus:'completed'}},
  {...raw('denied',{presentation:'dynamicTool',name:'Read',input:'{}',output:'Denied',status:'denied'}),workContext:{sourceStatus:'failed',toolNonExecutionKind:'permission-rule'}},
  {...raw('cancelled',{presentation:'dynamicTool',name:'Read',input:'{}',output:'Stopped',status:'failed'}),workContext:{sourceStatus:'cancelled',toolNonExecutionKind:'cancelled'}},
  {id:'stream',kind:'assistant',text:'Inspecting',isComplete:false,createdAt:time},
 ]};
 const projected=projectNativeSnapshot(active);
 const encode=Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem));
 for(const row of projected.visibleTurnItems)expect(()=>encode(row.item)).not.toThrow();
 for(const entry of projected.timelineEntries.filter((entry:any)=>entry.kind==='work')){
  const row=projected.visibleTurnItems.find((row:any)=>row.item.id===entry.id)!;
  expect(entry).toEqual(source.deriveTimelineEntriesFromVisibleTurnItems({visibleTurnItems:[row],optimisticMessages:[]})[0]);
 }
 expect((projected.timelineEntries.find(entry=>entry.id==='exit')as any).entry.toolLifecycleStatus).toBe('completed');
 expect((projected.timelineEntries.find(entry=>entry.id==='denied')as any).entry.toolLifecycleStatus).toBe('failed');
 expect((projected.timelineEntries.find(entry=>entry.id==='cancelled')as any).entry.toolLifecycleStatus).toBe('stopped');
 expect(projected.followModel).toMatchObject({threadStatus:'live',activityRun:{runId:'native-turn:prompt',status:'running'},runningRunId:'native-turn:prompt'});
 expect(projected.followModel.projection.visibleTurnItems.find((row:any)=>row.item.type==='user_message')?.item.runId).toBe('native-turn:prompt');
 expect(projected.toolItems.get('exit').providerTurnId).toBe('provider-real');
 expect(projectNativeSnapshot({...active,connectionState:'cached'}).followModel.threadStatus).toBe('cached');
});

it('renders observed reasoning and compaction through the pinned source timeline',async()=>{
 const items=[
  {id:'thinking',kind:'tool',text:'Thinking',detail:'Inspect the actual provider content.',isComplete:true,createdAt:time,updatedAt:time,workContext:{itemType:'reasoning',sourceStatus:'completed'}},
  {id:'compact',kind:'tool',text:'Context compacted',isComplete:true,createdAt:time,updatedAt:time,workContext:{itemType:'compaction',sourceStatus:'completed',beforeTokenCount:12000,afterTokenCount:5801}},
 ];
 const projected=projectNativeSnapshot({...snapshot,provider:'claude',items});
 const encode=Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem));
 for(const row of projected.visibleTurnItems)expect(()=>encode(row.item)).not.toThrow();
 expect(projected.toolItems.get('thinking')).toMatchObject({type:'reasoning',text:items[0].detail,streaming:false,status:'completed'});
 expect(projected.toolItems.get('compact')).toMatchObject({type:'compaction',driver:'claudeAgent',beforeTokenCount:12000,afterTokenCount:5801,status:'completed'});
 expect((projected.timelineEntries[0]as any).entry).toMatchObject({tone:'thinking',detail:items[0].detail});
 const props:any={...projected,listRef:createRef(),routeThreadKey:'fixture:reasoning-compaction',onOpenThread:()=>{},supportsConversationRollback:false,onRevertToTurnCount:()=>{},isRevertingCheckpoint:false,onImageExpand:()=>{},activeThreadEnvironmentId:EnvironmentId.make('fixture'),markdownCwd:undefined,resolvedTheme:'light',timestampFormat:'locale',workspaceRoot:undefined,anchorMessageId:null,onAnchorReady:()=>{},onAnchorSizeChanged:()=>{},contentInsetEndAdjustment:0,emptyPlaceholderInset:0,liveFollowEnabled:false,onIsAtEndChange:()=>{}};
 await using screen=await render(<div style={{height:700,width:800}}><MessagesTimeline {...props}/></div>);
 await expect.element(screen.getByRole('separator').filter({hasText:'Context compacted'})).toBeVisible();
 const {contextCompactionTokenCounts}=await import('@conversation/client-runtime/work-log/presentation');
 const labels=contextCompactionTokenCounts(projected.toolItems.get('compact'))!;
 expect(screen.container.textContent).toContain(labels.before);
 expect(screen.container.textContent).toContain(labels.after);
 const running=projectNativeSnapshot({...snapshot,provider:'codex',items:[{...items[1],text:'Compacting context',isComplete:false,workContext:{itemType:'compaction',sourceStatus:'running'}}]});
 expect(running.toolItems.get('compact').beforeTokenCount).toBeUndefined();
 expect(running.toolItems.get('compact').afterTokenCount).toBeUndefined();
 expect(running.toolItems.get('compact').completedAt).toBeNull();
 expect(running.toolItems.get('compact').driver).toBe('codex');
});

it('projects observed proposals, todo steps and explicit errors without inventing backend graph data',async()=>{
 const items:any[]=[
  {id:'proposal',kind:'tool',text:'Proposed plan',detail:'## Observed proposal\n\nInspect the source before editing.',isComplete:true,createdAt:time,updatedAt:time,workContext:{itemType:'proposed_plan',sourceStatus:'completed',planStatus:'active'}},
  {id:'todo_list:tool',kind:'tool',text:'Updated plan',detail:JSON.stringify({steps:[{id:'todo-0',text:'Inspect actual source',status:'completed'},{id:'todo-2',text:'Verify rendering',status:'running'}],explanation:'Observed provider steps'}),isComplete:true,createdAt:time,updatedAt:time,workContext:{itemType:'todo_list',sourceStatus:'completed',planStatus:'active'}},
  {id:'failure',kind:'notice',text:'Observed provider disconnect',isComplete:true,createdAt:time,updatedAt:time,workContext:{itemType:'error',sourceStatus:'failed'}},
 ];
 const projection=projectNativeSnapshot({...snapshot,items});
 const encode=Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem));
 for(const row of projection.visibleTurnItems)expect(()=>encode(row.item)).not.toThrow();
 expect(projection.timelineEntries.map(entry=>entry.kind)).toEqual(['proposed-plan','work','work']);
 expect((projection.timelineEntries[0]as any).proposedPlan).toMatchObject({planMarkdown:items[0].detail,status:'active'});
 expect(projection.toolItems.get('todo_list:tool').steps).toEqual(JSON.parse(items[1].detail).steps);
 expect(projection.toolItems.get('failure')).toMatchObject({type:'error',status:'failed',failure:{class:'unknown',message:items[2].text,code:null,retryable:null}});
 expect((projection.timelineEntries[2]as any).entry.label).toBe('Provider error');
 expect(projection.visibleTurnItems.every((row:any)=>row.item.nodeId===null)).toBe(true);
 const todo=projection.visibleTurnItems.find((row:any)=>row.item.type==='todo_list')!;
 await using screen=await render(<WorkLogRow label="Observed plan"><WorkLogDetails kind="panel"><V2ItemInspector environmentId={EnvironmentId.make('fixture')} projectedItem={todo}/></WorkLogDetails></WorkLogRow>);
 await expect.element(screen.getByText('Inspect actual source',{exact:false}).first()).toBeVisible();
 await expect.element(screen.getByText('Verify rendering',{exact:false}).first()).toBeVisible();
 const truncated=projectNativeSnapshot({...snapshot,items:[{...items[1],detail:'[Earlier text truncated]\n...invalid JSON'}]});
 expect(truncated.toolItems.get('todo_list:tool')).toMatchObject({type:'dynamic_tool',output:'[Earlier text truncated]\n...invalid JSON'});
 expect(()=>encode(truncated.toolItems.get('todo_list:tool'))).not.toThrow();
 const stopped=projectNativeSnapshot({...snapshot,items:[{...items[0],isComplete:true,workContext:{itemType:'proposed_plan',sourceStatus:'running',planStatus:'active'}}]});
 expect(stopped.toolItems.get('proposal').streaming).toBe(true);
 expect(stopped.toolItems.get('proposal').completedAt).toBeNull();
});
