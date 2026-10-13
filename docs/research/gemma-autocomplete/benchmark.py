import json,time,urllib.request,pathlib,statistics
BASE='http://localhost:11434/api/'
def post(endpoint,payload):
    req=urllib.request.Request(BASE+endpoint,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
    return urllib.request.urlopen(req,timeout=120)
post('generate',{'model':'gemma3:270m','keep_alive':0}).read()
rows=[]
cases=[('cold','как приготовить'),('warm','как приготовить'),('warm','как настроить'),('warm','погода в'),('warm','купить'),('warm','YouTube'),('warm','how to cook'),('warm','best laptop for'),('warm','ютуб')]
for state,prefix in cases:
    prompt='Complete the search prefix into 3 useful web search queries. Each query must start with the EXACT prefix. Use the same language as the prefix. Return only 3 lines, no numbering, no explanations.\nSearch prefix: '+prefix
    start=time.perf_counter();first=None;chunks=[];final={}
    with post('generate',{'model':'gemma3:270m','prompt':prompt,'stream':True,'keep_alive':'5m','options':{'num_ctx':1024,'num_predict':80,'temperature':0,'seed':42}}) as stream:
        for line in stream:
            item=json.loads(line)
            if item.get('response'):
                if first is None:first=time.perf_counter()-start
                chunks.append(item['response'])
            if item.get('done'):final=item
    row={'state':state,'prefix':prefix,'first_ms':None if first is None else round(first*1000),'total_ms':round((time.perf_counter()-start)*1000),'load_ms':round(final.get('load_duration',0)/1e6),'tokens':final.get('eval_count'),'tokens_s':round(final.get('eval_count',0)/(final['eval_duration']/1e9),1) if final.get('eval_duration',0)>0 else None,'done_reason':final.get('done_reason'),'text':''.join(chunks)}
    rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
with urllib.request.urlopen(BASE+'ps') as response:memory=json.load(response)
pathlib.Path(__file__).with_name('results.json').write_text(json.dumps({'model':'gemma3:270m','hardware':'Apple M1, 8 GB','options':{'num_ctx':1024,'num_predict':80,'temperature':0,'seed':42},'cases':rows,'ollama_ps':memory},ensure_ascii=False,indent=2))
print('MEMORY',json.dumps(memory),flush=True)
