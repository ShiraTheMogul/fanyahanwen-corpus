import csv
import io
import json

# Take in a .csv file labeled "input.csv" as input.
# The first column should list the words and the second column should list their frequency in occurrences.
with io.open('input.csv', mode='r', encoding='utf-8', newline='') as csv_file:
    reader = csv.DictReader(csv_file, fieldnames=('word','occurrences'))
    
    term_bank = []
    for row in reader:
        frequency = {}
        frequency['value'] = int(row['occurrences'])
        frequency['displayValue'] = row['occurrences']
        term_bank.append((row['word'], 'freq', frequency))
    
    with io.open('output.json', mode='w', encoding='utf-8') as fp:
        json.dump(term_bank, fp, ensure_ascii=False, indent=4)
