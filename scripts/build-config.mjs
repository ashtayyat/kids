import{readFileSync,writeFileSync}from'node:fs';import{publicConfig}from'../identity.mjs';
const url=process.env.SUPABASE_URL||'',key=process.env.SUPABASE_PUBLISHABLE_KEY||'';
const stored=JSON.parse(readFileSync('config.json','utf8'));const config=url||key?publicConfig({url,key}):stored.url?publicConfig(stored):{url:'',key:''};
writeFileSync('public/config.json',JSON.stringify(config));
if(!config.url)console.log('Shared project config not set: setup screen will remain visible.');
