import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {join} from 'node:path';
const directory=process.argv[2]||'public',version=process.env.GITHUB_SHA||'v16';
if(!/^[a-zA-Z0-9_-]+$/.test(version))throw Error('Invalid asset version');
for(const name of readdirSync(directory).filter(n=>/\.(?:m?js)$/.test(n))){const path=join(directory,name);let source=readFileSync(path,'utf8');source=source.replace(/(from\s*['"])(\.\/[^'"?]+\.(?:m?js))(?:\?v=[^'"]+)?(['"])/g,`$1$2?v=${version}$3`);writeFileSync(path,source)}
const path=join(directory,'index.html');writeFileSync(path,readFileSync(path,'utf8').replace(/(src|href)="(app\.js|style\.css)(?:\?v=[^"]+)?"/g,`$1="$2?v=${version}"`));
