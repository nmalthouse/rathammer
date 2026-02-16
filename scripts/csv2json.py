import sys
import csv
import json

out = {}

with open(sys.argv[1]) as infile:
    read = csv.reader(infile)
    for line in read:

        dictout = out
        namespaces = line[0].split('.')

        for i in range(0, len(namespaces) - 1):
            if not namespaces[i] in dictout:
                dictout[namespaces[i]] = {}
            dictout = dictout[namespaces[i]]

        dictout[namespaces[-1]] = line[1].strip()


if len(sys.argv) > 2:
    with open(sys.argv[2], mode='w') as outfile:
        outfile.write(json.dumps(out))
else:
    print(json.dumps(out))

