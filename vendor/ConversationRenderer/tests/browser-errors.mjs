import assert from 'node:assert/strict';
import {classifyBrowserError} from '../src/browserErrors.ts';
for(const message of ['ResizeObserver loop completed with undelivered notifications.','ResizeObserver loop limit exceeded']){
 assert.equal(classifyBrowserError({message,error:null}).type,'renderDiagnostic');
 assert.equal(classifyBrowserError({message,error:new Error('Actual JavaScript exception')}).type,'error');
}
assert.equal(classifyBrowserError({message:'Unexpected application failure',error:null}).type,'error');
assert.equal(classifyBrowserError({message:'ResizeObserver loop completed with undelivered notifications. Unexpected suffix',error:null}).type,'error');
console.log('Browser notification classification passed');
