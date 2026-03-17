lines = [['#漢字', '音標', '解釋']]

with open('data.tsv', encoding='utf-8') as f:
    next(f)
    for line in f:
        line = line.strip().split('\t')
        if line[7] == '此字當刪':
            continue
        音標 = line[9] + str('平上去入'.index(line[3]) + 1)
        解釋 = line[2]
        if line[6]:
            解釋 += ' ' + line[6]
        if line[8]:
            解釋 += ' 校註：' + line[8]
        if line[6] and line[8]:
            print(line)
        for 漢字 in line[4] + line[5]:
            lines.append([漢字, 音標, 解釋])

字音對s = set()
for line in lines:
    字音對 = tuple(line[:2])
    if 字音對 in 字音對s:
        print(line)
    字音對s.add(字音對)

with open('蒙古字韻.tsv', 'w', encoding='utf-8') as f:
    for line in lines:
        f.write('\t'.join(line) + '\n')
