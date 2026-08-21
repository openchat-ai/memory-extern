import json
d = json.load(open('/tmp/rel.json'))
print('tag:', d['tag_name'])
for a in d['assets']:
    print(a['name'], a['size'])