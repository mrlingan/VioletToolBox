#!/usr/bin/env python3
"""Record the checked-out Windows UI event baseline; never execute vendor tools."""
import collections, json, pathlib, re, subprocess, xml.etree.ElementTree as ET
root = pathlib.Path(__file__).resolve().parents[2]
items = collections.OrderedDict()
for xaml in sorted((root/'VioletToolBox').rglob('*.xaml')):
    try: tree = ET.parse(xaml)
    except ET.ParseError: continue
    for element in tree.iter():
        for event in ('Click','Drop','SelectionChanged','Checked','Unchecked'):
            handler = element.get(event)
            if not handler: continue
            labels=[]
            for child in element.iter():
                for key in ('Content','Text','ToolTip','Header'):
                    label=child.get(key,'')
                    if label and not label.startswith('{') and label not in labels: labels.append(label)
            row=items.setdefault(handler,{'handler':handler,'ui':[],'source':[]})
            row['ui'].append({'file':str(xaml.relative_to(root)),'event':event,'name':element.get('{http://schemas.microsoft.com/winfx/2006/xaml}Name',''),'label':' / '.join(labels)[:300]})
for source in sorted((root/'VioletToolBox').rglob('*.cs')):
    for index,line in enumerate(source.read_text(errors='replace').splitlines(),1):
        match=re.search(r'(?:private|public|protected|internal)\s+(?:static\s+)?(?:async\s+)?[\w<>?]+\s+(\w+)\s*\(',line)
        if match and match[1] in items: items[match[1]]['source'].append({'file':str(source.relative_to(root)),'line':index})
result={'upstream_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'note':'UI events are an audit index, not a count of user features. Dynamic controls and backend behavior require manual audit.','handlers':list(items.values())}
out=root/'macOS'/'WINDOWS_ACTIONS.json';out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(f'{len(items)} unique handlers indexed in {out.name}')
