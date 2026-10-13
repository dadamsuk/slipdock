// Makes test/support/fixtures/excalidraw/*: a drawing in the Obsidian
// Excalidraw plugin's compressed format, compressed by lz-string itself.
// Run with lz-string installed: node make.cjs test/support/fixtures/excalidraw
const fs=require('fs');const LZ=require('lz-string');const out=process.argv[2];
const base={angle:0,strokeColor:"#1e1e1e",backgroundColor:"transparent",fillStyle:"solid",strokeWidth:2,strokeStyle:"solid",roughness:1,opacity:100,groupIds:[],frameId:null,roundness:null,seed:1,version:1,versionNonce:1,isDeleted:false,boundElements:null,updated:1,link:null,locked:false};
const els=[
 {...base,id:"box1",type:"rectangle",x:0,y:0,width:200,height:100,backgroundColor:"#a5d8ff",roundness:{type:3},boundElements:[{type:"text",id:"txtA1b2c"}]},
 {...base,id:"txtA1b2c",type:"text",x:40,y:37.5,width:120,height:25,text:"Ship it",originalText:"Ship it",fontSize:20,fontFamily:5,textAlign:"center",verticalAlign:"middle",containerId:"box1",lineHeight:1.25},
 {...base,id:"oval1",type:"ellipse",x:300,y:0,width:120,height:80,fillStyle:"hachure",backgroundColor:"#ffc9c9"},
 {...base,id:"arrow1",type:"arrow",x:200,y:50,width:100,height:-10,points:[[0,0],[100,-10]],endArrowhead:"arrow",startArrowhead:null,roundness:{type:2}},
 {...base,id:"txtZ9y8x",type:"text",x:0,y:150,width:300,height:50,text:"Second line\nof notes ✓",originalText:"Second line of notes ✓",fontSize:20,fontFamily:1,textAlign:"left",verticalAlign:"top",containerId:null,lineHeight:1.25},
 {...base,id:"gone1",type:"text",x:0,y:300,width:10,height:10,text:"deleted words",originalText:"deleted words",fontSize:20,fontFamily:1,isDeleted:true},
 {...base,id:"img1",type:"image",x:450,y:0,width:64,height:64,fileId:"f00d",status:"saved",scale:[1,1]}
];
const scene={type:"excalidraw",version:2,source:"https://github.com/zsviczian/obsidian-excalidraw-plugin/releases/tag/2.17.2",elements:els,appState:{theme:"light",viewBackgroundColor:"#ffffff",gridSize:null},files:{}};
const json=JSON.stringify(scene,null,"\t");
const c=LZ.compressToBase64(json);let chunks=[];for(let i=0;i<c.length;i+=256)chunks.push(c.slice(i,i+256));
const md=`==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'


# Excalidraw Data

## Text Elements
Ship it ^txtA1b2c

Second line of notes ✓ ^txtZ9y8x

## Embedded Files
f00d: [[cat.png]]

%%
## Drawing
\`\`\`compressed-json
${chunks.join("\n\n")}
\`\`\`
%%`;
fs.writeFileSync(out+"/Sketch.excalidraw.md", md);
fs.writeFileSync(out+"/sketch.json", json);
