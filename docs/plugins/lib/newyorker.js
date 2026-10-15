// Publisher-specific content normalization, embedded in the web and access plugins.
// Both normal saves/owner refreshes and archive/browser recovery use the same rule.
const LunaNewYorker = (() => {
    function prepare(html,url) {
        const host=(luna.parseURL(url)||{}).hostname||'';
        if(host!=='newyorker.com'&&!host.endsWith('.newyorker.com'))return html;
        // New Yorker marks ordinary continuation paragraphs as `paywall`.
        // Its JSON-LD articleBody can omit the unmarked opening paragraph,
        // so keep the complete DOM body instead of falling back to that text.
        const doc=luna.html.parse(html,url);
        const paragraphs=doc.querySelectorAll('[data-testid="BodyWrapper"] .body__inner-container > p.paywall');
        if(paragraphs.length) {
            html='<html><head>'+(doc.head?doc.head.innerHTML:'')+'</head><body><article>'+
                doc.querySelectorAll('[data-testid="BodyWrapper"]').map(n=>n.outerHTML).join('\n')+
                '</article></body></html>';
            for(const p of paragraphs) {
                const attributes=p.attributes;
                attributes.class=attributes.class.split(/\s+/).filter(c=>c!=='paywall').join(' ');
                const opening='<p'+Object.keys(attributes).map(k=>' '+k+'="'+LunaWeb.escape(attributes[k])+'"').join('')+'>';
                html=html.replace(p.outerHTML,()=>opening+p.innerHTML+'</p>');
            }
        }
        return html;
    }
    return {prepare};
})();
