import React,{useState} from 'react';
import {RenderErrorBoundary} from '@conversation-source/components/RenderErrorBoundary';
import {mountConversation} from '../src/reactRoot';
import {resolveNative} from '../src/bridge';
function BrokenWidget():React.ReactNode{throw new Error('Intentional widget render failure');}
let update:(value:string)=>void;
window.TabConversation={update(snapshot){update(String(snapshot.status));},resolve:resolveNative};
function Harness(){const[mode,setMode]=useState('healthy');update=setMode;if(mode==='root')throw new Error('Intentional whole-body render failure');return <><p data-conversation-retained>Conversation remains visible</p>{mode==='widget'?<RenderErrorBoundary fallback={<p data-source-widget-fallback>Actual source widget fallback</p>}><BrokenWidget/></RenderErrorBoundary>:null}</>;}
mountConversation(document.getElementById('root')!,<Harness/>);
