/* Minimal runtime for the Combat design files (.dc.html): renders the same markup and logic the mockup uses. */
(function(){
  class DCLogic{constructor(p){this.props=p||{};this.state={}}setState(p){Object.assign(this.state,typeof p==='function'?p(this.state):p);this.__render&&this.__render()}}
  const BIND=/\{\{\s*([^}]*?)\s*\}\}/g, ONE=/^\s*\{\{\s*([^}]*?)\s*\}\}\s*$/;
  function get(scope,path){let v=scope;for(const k of path.split('.')){if(v==null)return undefined;v=v[k]}return v}
  function str(v){return v==null||v===false?'':String(v)}
  function build(nodes,scope,parent){
    nodes.forEach(n=>{
      if(n.nodeType===3){const t=n.textContent.replace(BIND,(_,p)=>str(get(scope,p)));parent.appendChild(document.createTextNode(t));return}
      if(n.nodeType!==1)return;
      const tag=n.localName;
      if(tag==='helmet')return;
      if(tag==='sc-for'){const list=get(scope,(n.getAttribute('list')||'').replace(/[{}\s]/g,''))||[],as=n.getAttribute('as')||'item';
        list.forEach(it=>{const sc=Object.create(scope);sc[as]=it;build([...n.childNodes],sc,parent)});return}
      if(tag==='sc-if'){const v=get(scope,(n.getAttribute('value')||'').replace(/[{}\s]/g,''));if(v)build([...n.childNodes],scope,parent);return}
      const el=n.namespaceURI&&n.namespaceURI!=='http://www.w3.org/1999/xhtml'?document.createElementNS(n.namespaceURI,tag):document.createElement(tag);
      [...n.attributes].forEach(a=>{
        const name=a.name;if(name.startsWith('hint-placeholder'))return;
        const m=a.value.match(ONE);
        if(m){const v=get(scope,m[1]);
          if(/^on/.test(name)){if(typeof v==='function')el.addEventListener(name.slice(2).toLowerCase(),v);return}
          if(typeof v==='boolean'){if(name.startsWith('aria-')||name.startsWith('data-'))el.setAttribute(name,String(v));else if(v)el.setAttribute(name,'');return}
          if(v==null)return;el.setAttribute(name,String(v));return}
        el.setAttribute(name,a.value.replace(BIND,(_,p)=>str(get(scope,p))));
      });
      build([...n.childNodes],scope,el);
      parent.appendChild(el);
    });
  }
  async function mount({url,root,patch,patchText}){
    let text=await (await fetch(url,{cache:'no-cache'})).text();
    if(patchText)text=patchText(text);
    const doc=new DOMParser().parseFromString(text,'text/html');
    const xdc=doc.querySelector('x-dc');
    const helm=xdc.querySelector('helmet');
    if(helm)[...helm.childNodes].forEach(c=>{if(c.nodeType===1){const k=c.cloneNode(true);document.head.appendChild(k)}});
    let script=doc.querySelector('script[data-dc-script]').textContent;
    if(patch)script=patch(script);
    const C=new Function('DCLogic',script+'\n;return Component;')(DCLogic);
    const inst=new C({});
    const nodes=[...xdc.childNodes];
    inst.__render=function(){
      const sc=[...root.querySelectorAll('.scroll')].map(e=>e.scrollTop);
      const vals=inst.renderVals();
      const frag=document.createDocumentFragment();
      build(nodes,vals,frag);
      root.replaceChildren(frag);
      root.querySelectorAll('.scroll').forEach((e,i)=>{if(sc[i])e.scrollTop=sc[i]});
    };
    inst.__render();
    return inst;
  }
  window.DCRuntime={mount};
})();
