// Makes lz_string_vectors.json with the lz-string npm package itself:
//   npm install lz-string && node lz_string_vectors.cjs > lz_string_vectors.json
const LZ=require('lz-string');
const inputs=["a","Hello, world!","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","TOBEORNOTTOBEORTOBEORNOT#","héllo wörld — “quotes” ✓","emoji 🎨🖌️ and 漢字 and тест",
JSON.stringify({type:"excalidraw",version:2,source:"https://excalidraw.com",elements:[{id:"abc",type:"text",text:"Hi ^ there",x:1.5,y:-2}],appState:{viewBackgroundColor:"#ffffff"},files:{}}),
Array.from({length:400},(_, i)=>String.fromCharCode(32+((i*7919)%300))).join("")];
console.log(JSON.stringify({source:"lz-string "+require('lz-string/package.json').version+" compressToBase64",vectors:inputs.map(i=>({plain:i,compressed:LZ.compressToBase64(i)}))},null,1));
